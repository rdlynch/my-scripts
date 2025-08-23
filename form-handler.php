<?php
/**
 * Alpha Omega Strategies – Secure form handler
 * Path: /var/www/form-handler.php (installed by server-setup.sh)
 * Config: /etc/aos-form-secrets (INI with sections [app], [smtp], [security], [logging])
 *
 * Defaults:
 * - Transport: HTTP API to Postmark; fallback to SMTP (same Server Token)
 * - Anti-abuse: host & referer allowlist, honeypot, min submit time, per-IP rate limit, optional CAPTCHA
 * - Attachments: size/type enforcement; API embeds as base64
 * - Logging: JSON lines with redaction, to /var/log/forms/contact.log
 *
 * Responses: JSON with HTTP codes
 *   200 ok
 *   400 bad request (validation)
 *   403 forbidden (origin/referer/captcha)
 *   429 too many (rate limit)
 *   500 server error (send failure)
 */

declare(strict_types=1);
set_time_limit(10);

// -------------------- Bootstrap --------------------
if ($_SERVER['REQUEST_METHOD'] !== 'POST') {
    http_response_code(405);
    header('Content-Type: application/json');
    echo json_encode(['ok' => false, 'error' => 'method_not_allowed']);
    exit;
}

$config_file = '/etc/aos-form-secrets';
if (!is_readable($config_file)) {
    http_response_code(500);
    header('Content-Type: application/json');
    echo json_encode(['ok' => false, 'error' => 'config_missing']);
    exit;
}
$cfg = parse_ini_file($config_file, true, INI_SCANNER_TYPED);

// Sections with sane defaults
$app     = $cfg['app']      ?? [];
$smtp    = $cfg['smtp']     ?? [];
$sec     = $cfg['security'] ?? [];
$logcfg  = $cfg['logging']  ?? [];

$env         = $app['environment'] ?? 'production';
$site_name   = $app['site_name'] ?? 'Website';
$allowed_hosts = array_filter(array_map('trim', explode(',', (string)($app['allowed_hosts'] ?? ''))));
$allowed_refs  = array_filter(array_map('trim', explode(',', (string)($app['allowed_referers'] ?? ''))));
$from_name   = $app['from_name'] ?? $site_name . ' Contact';
$from_email  = $app['from_email'] ?? ('no-reply@' . ($_SERVER['HTTP_HOST'] ?? 'localhost'));
$to          = array_filter(array_map('trim', explode(',', (string)($app['to'] ?? ''))));
$cc          = array_filter(array_map('trim', explode(',', (string)($app['cc'] ?? ''))));
$bcc         = array_filter(array_map('trim', explode(',', (string)($app['bcc'] ?? ''))));
$subject_prefix = trim((string)($app['subject_prefix'] ?? ''));
$subject_prefix = $subject_prefix ? ($subject_prefix . ' ') : '';

$transport     = strtolower((string)($smtp['transport'] ?? 'api')); // "api" or "smtp"
$smtp_host     = $smtp['host'] ?? 'smtp.postmarkapp.com';
$smtp_port     = (int)($smtp['port'] ?? 587);
$smtp_user     = $smtp['username'] ?? '';
$smtp_pass     = $smtp['password'] ?? '';
$smtp_enc      = strtolower((string)($smtp['encryption'] ?? 'tls'));
$smtp_timeout  = (int)($smtp['timeout'] ?? 15);

$csrf_secret   = (string)($sec['csrf_secret'] ?? '');
$hmac_secret   = (string)($sec['hmac_secret'] ?? '');
$captcha_provider = strtolower((string)($sec['captcha_provider'] ?? 'none'));
$captcha_sitekey  = (string)($sec['captcha_sitekey'] ?? '');
$captcha_secret   = (string)($sec['captcha_secret'] ?? '');
$honeypot_field   = (string)($sec['honeypot_field'] ?? 'website');
$min_submit_seconds = (int)($sec['min_submit_seconds'] ?? 3);
$rate_window  = (int)($sec['rate_window_seconds'] ?? 900);
$rate_max     = (int)($sec['rate_max_submissions'] ?? 5);
$block_disposable = (bool)($sec['block_disposable'] ?? true);
$max_body_chars   = (int)($sec['max_body_chars'] ?? 8000);
$allowed_attachs  = array_filter(array_map('strtolower', array_map('trim', explode(',', (string)($sec['allowed_attachment_types'] ?? 'pdf,doc,docx,png,jpg,jpeg')))));
$max_attach_mb    = (int)($sec['max_attachment_mb'] ?? 5);

$log_file      = $logcfg['log_file'] ?? '/var/log/forms/contact.log';
$log_json      = (bool)($logcfg['log_json'] ?? true);
$log_redact    = array_filter(array_map('trim', explode(',', (string)($logcfg['log_redact_fields'] ?? 'password,token,csrf,captcha,attachment'))));
$log_level     = strtolower((string)($logcfg['log_level'] ?? 'info'));

// Where we keep per-IP counters
$rate_dir = '/var/cache/aos-forms';
if (!is_dir($rate_dir)) {
    @mkdir($rate_dir, 02770, true);
    @chgrp($rate_dir, 'www-data');
}

// -------------------- Helpers --------------------
function json_resp(int $code, array $payload): void {
    http_response_code($code);
    header('Content-Type: application/json; charset=utf-8');
    echo json_encode($payload, JSON_UNESCAPED_SLASHES);
    exit;
}

function redact(array $data, array $keys): array {
    $out = $data;
    foreach ($keys as $k) {
        if (array_key_exists($k, $out)) {
            $out[$k] = '[REDACTED]';
        }
    }
    return $out;
}

function log_json_line(string $file, array $event): void {
    $dir = dirname($file);
    if (!is_dir($dir)) @mkdir($dir, 02750, true);
    $line = json_encode($event, JSON_UNESCAPED_SLASHES);
    // Best effort; do not throw
    @file_put_contents($file, $line . PHP_EOL, FILE_APPEND | LOCK_EX);
    @chmod($file, 0640);
    @chgrp($file, 'www-data');
}

function client_ip(): string {
    // Trust only direct REMOTE_ADDR behind Caddy unless you terminate elsewhere
    return $_SERVER['REMOTE_ADDR'] ?? '0.0.0.0';
}

function host_allowed(array $allowed_hosts): bool {
    if (!$allowed_hosts) return true; // permissive if not set
    $host = $_SERVER['HTTP_HOST'] ?? '';
    $host = strtolower(preg_replace('/:\d+$/', '', $host));
    return in_array($host, array_map('strtolower', $allowed_hosts), true);
}

function referer_allowed(array $allowed_refs): bool {
    if (!$allowed_refs) return true; // permissive if not set
    $ref = $_SERVER['HTTP_REFERER'] ?? '';
    if ($ref === '') return false;
    foreach ($allowed_refs as $ok) {
        if (stripos($ref, $ok) === 0) return true;
    }
    return false;
}

function too_fast(?string $ts, int $min): bool {
    if (!$ts || !ctype_digit($ts)) return false; // if not provided, skip
    $age = time() - (int)$ts;
    return $age < $min;
}

function rate_check(string $ip, string $dir, int $window, int $max): bool {
    $file = $dir . '/rl_' . preg_replace('/[^0-9a-fA-F:.]/', '_', $ip) . '.json';
    $now = time();
    $data = ['start' => $now, 'count' => 0];
    if (is_file($file)) {
        $raw = @file_get_contents($file);
        if ($raw) {
            $data = json_decode($raw, true) ?: $data;
        }
        if (($now - ($data['start'] ?? $now)) > $window) {
            $data = ['start' => $now, 'count' => 0];
        }
    }
    $data['count'] = (int)($data['count'] ?? 0) + 1;
    @file_put_contents($file, json_encode($data), LOCK_EX);
    @chmod($file, 0660);
    @chgrp($file, 'www-data');
    return $data['count'] <= $max;
}

function is_disposable_email(string $email): bool {
    $parts = explode('@', strtolower($email));
    if (count($parts) !== 2) return true;
    [$local, $domain] = $parts;
    if (!filter_var($email, FILTER_VALIDATE_EMAIL)) return true;
    // quick common disposable domain patterns
    $bad = [
        'mailinator.com','10minutemail.com','guerrillamail.com','tempmail.','trashmail.',
        'yopmail.com','getnada.com','dropmail.','moakt.','sharklasers.com','grr.la',
    ];
    foreach ($bad as $b) {
        if (str_contains($domain, $b)) return true;
    }
    return false;
}

function clean_text(string $s, int $max): string {
    $s = trim(str_replace(["\r\n", "\r"], "\n", $s));
    $s = preg_replace('/[[:^print:]\t]/u', '', $s);
    if (mb_strlen($s, 'UTF-8') > $max) {
        $s = mb_substr($s, 0, $max, 'UTF-8');
    }
    return $s;
}

function verify_captcha(string $provider, string $secret, string $token, string $ip): bool {
    if ($provider === 'none' || $provider === '') return true;
    if ($token === '' || $secret === '') return false;

    $endpoints = [
        'turnstile' => 'https://challenges.cloudflare.com/turnstile/v0/siteverify',
        'hcaptcha'  => 'https://hcaptcha.com/siteverify',
        'recaptcha' => 'https://www.google.com/recaptcha/api/siteverify',
    ];
    $url = $endpoints[$provider] ?? '';
    if ($url === '') return false;

    $ch = curl_init($url);
    $post = http_build_query(['secret' => $secret, 'response' => $token, 'remoteip' => $ip]);
    curl_setopt_array($ch, [
        CURLOPT_RETURNTRANSFER => true,
        CURLOPT_POST => true,
        CURLOPT_POSTFIELDS => $post,
        CURLOPT_TIMEOUT => 8,
        CURLOPT_HTTPHEADER => ['Content-Type: application/x-www-form-urlencoded'],
    ]);
    $resp = curl_exec($ch);
    if ($resp === false) return false;
    $code = curl_getinfo($ch, CURLINFO_RESPONSE_CODE);
    curl_close($ch);
    if ($code !== 200) return false;
    $json = json_decode($resp, true);
    if (!is_array($json)) return false;

    if ($provider === 'recaptcha') {
        return !empty($json['success']);
    }
    // Turnstile/hCaptcha use 'success' too
    return !empty($json['success']);
}

function postmark_api_send(array $payload, string $server_token): array {
    $ch = curl_init('https://api.postmarkapp.com/email');
    curl_setopt_array($ch, [
        CURLOPT_RETURNTRANSFER => true,
        CURLOPT_POST => true,
        CURLOPT_POSTFIELDS => json_encode($payload, JSON_UNESCAPED_SLASHES),
        CURLOPT_TIMEOUT => 10,
        CURLOPT_HTTPHEADER => [
            'Accept: application/json',
            'Content-Type: application/json',
            'X-Postmark-Server-Token: ' . $server_token,
        ],
    ]);
    $resp = curl_exec($ch);
    $err  = curl_error($ch);
    $info = curl_getinfo($ch);
    curl_close($ch);
    return ['ok' => ($info['http_code'] ?? 0) >= 200 && ($info['http_code'] ?? 0) < 300, 'code' => $info['http_code'] ?? 0, 'body' => $resp, 'err' => $err];
}

function smtp_send_simple(array $msg, string $host, int $port, string $enc, string $user, string $pass, int $timeout): array {
    // Minimal SMTP client for Postmark: STARTTLS then AUTH PLAIN, then DATA.
    $errno = 0; $errstr = '';
    $fp = @stream_socket_client("tcp://{$host}:{$port}", $errno, $errstr, $timeout, STREAM_CLIENT_CONNECT);
    if (!$fp) return ['ok' => false, 'err' => "connect: $errstr"];
    stream_set_timeout($fp, $timeout);

    $read = function() use ($fp) { return fgets($fp, 512); };
    $send = function($line) use ($fp) { fwrite($fp, $line . "\r\n"); };

    $banner = $read(); if (strpos($banner, '220') !== 0) return ['ok' => false, 'err' => 'no 220 banner'];

    $send('EHLO client.example');
    $ehlo = '';
    for ($i=0; $i<20; $i++) { $l = $read(); if ($l === false) break; $ehlo .= $l; if (preg_match('/^\d{3} /', $l)) break; }
    if (!str_contains($ehlo, 'STARTTLS')) return ['ok' => false, 'err' => 'no STARTTLS'];
    $send('STARTTLS');
    $tls = $read(); if (strpos($tls, '220') !== 0) return ['ok' => false, 'err' => 'starttls fail'];
    if (!stream_socket_enable_crypto($fp, true, STREAM_CRYPTO_METHOD_TLS_CLIENT)) return ['ok' => false, 'err' => 'tls enable fail'];

    $send('EHLO client.example');
    for ($i=0; $i<20; $i++) { $l = $read(); if ($l === false) break; if (preg_match('/^\d{3} /', $l)) break; }

    // AUTH PLAIN
    $auth = base64_encode("\0{$user}\0{$pass}");
    $send('AUTH PLAIN ' . $auth);
    $ok = $read(); if (strpos($ok, '235') !== 0) return ['ok' => false, 'err' => 'auth fail'];

    $send('MAIL FROM:<' . $msg['from'] . '>');
    if (strpos($read(), '250') !== 0) return ['ok' => false, 'err' => 'mail from fail'];

    $rcpts = array_merge([$msg['to']], $msg['cc'], $msg['bcc']);
    $rcpts = array_values(array_unique(array_filter($rcpts)));
    foreach ($rcpts as $r) {
        $send('RCPT TO:<' . $r . '>');
        if (strpos($read(), '250') !== 0) return ['ok' => false, 'err' => 'rcpt to fail: ' . $r];
    }

    $send('DATA');
    if (strpos($read(), '354') !== 0) return ['ok' => false, 'err' => 'data fail'];

    $headers = [];
    $headers[] = 'Date: ' . gmdate('D, d M Y H:i:s') . ' +0000';
    $headers[] = 'From: ' . $msg['from_name'] . ' <' . $msg['from'] . '>';
    $headers[] = 'To: ' . $msg['to'];
    if (!empty($msg['cc']))  $headers[] = 'Cc: ' . implode(', ', $msg['cc']);
    $headers[] = 'Subject: ' . $msg['subject'];
    $headers[] = 'MIME-Version: 1.0';
    $headers[] = 'X-PM-Message-Stream: outbound';
    if (!empty($msg['reply_to'])) $headers[] = 'Reply-To: ' . $msg['reply_to'];
    // Simple text email. If you need HTML, we can add multipart/alternative.
    $headers[] = 'Content-Type: text/plain; charset=UTF-8';
    $mime = implode("\r\n", $headers) . "\r\n\r\n" . $msg['text'] . "\r\n.";
    $send($mime);
    if (strpos($read(), '250') !== 0) return ['ok' => false, 'err' => 'message not accepted'];

    $send('QUIT'); $read();
    fclose($fp);
    return ['ok' => true];
}

// -------------------- Collect & validate input --------------------
$ip = client_ip();
$now = time();

// support application/x-www-form-urlencoded and multipart/form-data
$in = $_POST;

// Required minimum: a sender email and a message field
$user_email = clean_text((string)($in['email'] ?? ''), 320);
$user_name  = clean_text((string)($in['name'] ?? ''), 200);
$message    = clean_text((string)($in['message'] ?? ''), $max_body_chars);
$ts_field   = (string)($in['ts'] ?? ''); // optional timestamp from the form
$hp_value   = (string)($in[$honeypot_field] ?? '');

if (!host_allowed($allowed_hosts) || !referer_allowed($allowed_refs)) {
    log_json_line($log_file, ['ts'=>$now,'level'=>'warn','evt'=>'forbidden_origin','ip'=>$ip,'host'=>($_SERVER['HTTP_HOST']??''),'ref'=>($_SERVER['HTTP_REFERER']??'')]);
    json_resp(403, ['ok'=>false, 'error'=>'forbidden']);
}
if ($hp_value !== '') {
    log_json_line($log_file, ['ts'=>$now,'level'=>'warn','evt'=>'honeypot_trip','ip'=>$ip]);
    json_resp(200, ['ok'=>true]); // pretend success to not tip off bots
}
if (too_fast($ts_field, $min_submit_seconds)) {
    log_json_line($log_file, ['ts'=>$now,'level'=>'warn','evt'=>'too_fast','ip'=>$ip,'age'=>time()-(int)$ts_field]);
    json_resp(429, ['ok'=>false,'error'=>'too_fast']);
}
if (!rate_check($ip, $rate_dir, $rate_window, $rate_max)) {
    log_json_line($log_file, ['ts'=>$now,'level'=>'warn','evt'=>'rate_limit','ip'=>$ip]);
    json_resp(429, ['ok'=>false,'error'=>'rate_limited']);
}
if ($user_email === '' || !filter_var($user_email, FILTER_VALIDATE_EMAIL)) {
    json_resp(400, ['ok'=>false,'error'=>'invalid_email']);
}
if ($block_disposable && is_disposable_email($user_email)) {
    json_resp(400, ['ok'=>false,'error'=>'disposable_email_blocked']);
}
if ($message === '') {
    json_resp(400, ['ok'=>false,'error'=>'empty_message']);
}

// CAPTCHA optional
$captcha_ok = true;
if ($captcha_provider !== 'none') {
    $token = (string)($in['captcha'] ?? $in['cf-turnstile-response'] ?? $in['h-captcha-response'] ?? $in['g-recaptcha-response'] ?? '');
    $captcha_ok = verify_captcha($captcha_provider, $captcha_secret, $token, $ip);
    if (!$captcha_ok) {
        log_json_line($log_file, ['ts'=>$now,'level'=>'warn','evt'=>'captcha_fail','ip'=>$ip,'provider'=>$captcha_provider]);
        json_resp(403, ['ok'=>false,'error'=>'captcha_failed']);
    }
}

// Attachments (optional)
$attachments_api = [];
if (!empty($_FILES)) {
    $total_bytes = 0;
    foreach ($_FILES as $file) {
        if (($file['error'] ?? UPLOAD_ERR_NO_FILE) === UPLOAD_ERR_NO_FILE) continue;
        if (($file['error'] ?? UPLOAD_ERR_OK) !== UPLOAD_ERR_OK) {
            json_resp(400, ['ok'=>false,'error'=>'attachment_error']);
        }
        $name = (string)$file['name'];
        $size = (int)$file['size'];
        $tmp  = (string)$file['tmp_name'];
        $ext  = strtolower(pathinfo($name, PATHINFO_EXTENSION));
        if (!in_array($ext, $allowed_attachs, true)) {
            json_resp(400, ['ok'=>false,'error'=>'attachment_type']);
        }
        $total_bytes += $size;
        if ($total_bytes > ($max_attach_mb * 1024 * 1024)) {
            json_resp(400, ['ok'=>false,'error'=>'attachment_too_large']);
        }
        $mime = mime_content_type($tmp) ?: 'application/octet-stream';
        $b64  = base64_encode(file_get_contents($tmp));
        $attachments_api[] = ['Name'=>$name,'Content'=>$b64,'ContentType'=>$mime];
    }
}

// -------------------- Build message --------------------
$subject = $subject_prefix . 'New message from ' . ($user_name !== '' ? $user_name : $user_email);
$lines = [];
$lines[] = "From: " . ($user_name !== '' ? "$user_name <$user_email>" : $user_email);
$lines[] = "IP: $ip";
$lines[] = "Time (UTC): " . gmdate('Y-m-d H:i:s');
$lines[] = str_repeat('-', 40);
$lines[] = $message;
$text_body = implode("\n", $lines);

// Postmark JSON payload
$primary_to = $to[0] ?? '';
if ($primary_to === '') {
    json_resp(500, ['ok'=>false,'error'=>'recipient_missing']);
}
$payload = [
    'From' => sprintf('%s <%s>', $from_name, $from_email),
    'To' => implode(',', $to),
    'Cc' => implode(',', $cc),
    'Bcc' => implode(',', $bcc),
    'Subject' => $subject,
    'TextBody' => $text_body,
    'MessageStream' => 'outbound',
    'ReplyTo' => $user_email,
    'Headers' => [
        ['Name'=>'X-PM-Tag','Value'=>'contact'],
        ['Name'=>'X-AOS-Site','Value'=>$site_name],
    ],
];
if ($attachments_api) $payload['Attachments'] = $attachments_api;

// -------------------- Send: API first, SMTP fallback --------------------
$send_ok = false;
$api_result = null;
$smtp_result = null;

// Use API unless config says smtp only
if ($transport !== 'smtp') {
    $api_result = postmark_api_send($payload, $smtp_user ?: $smtp_pass);
    $send_ok = $api_result['ok'] ?? false;
}

if (!$send_ok) {
    // Fallback to SMTP using same token for username/password unless both set
    $smtp_msg = [
        'from' => $from_email,
        'from_name' => $from_name,
        'to' => $primary_to,
        'cc' => $cc,
        'bcc' => $bcc,
        'subject' => $subject,
        'text' => $text_body,
        'reply_to' => $user_email,
    ];
    $smtp_user_eff = $smtp_user ?: $smtp_pass;
    $smtp_pass_eff = $smtp_pass ?: $smtp_user;
    $smtp_result = smtp_send_simple($smtp_msg, $smtp_host, $smtp_port, $smtp_enc, $smtp_user_eff, $smtp_pass_eff, $smtp_timeout);
    $send_ok = $smtp_result['ok'] ?? false;
}

// -------------------- Log and respond --------------------
$log_event = [
    'ts' => $now,
    'level' => $send_ok ? 'info' : 'error',
    'evt' => 'submit',
    'ip' => $ip,
    'origin_host' => ($_SERVER['HTTP_HOST'] ?? ''),
    'referer' => ($_SERVER['HTTP_REFERER'] ?? ''),
    'captcha' => $captcha_provider,
    'transport' => $send_ok && ($api_result && ($api_result['ok'] ?? false)) ? 'api' : ($send_ok ? 'smtp' : 'none'),
    'status' => $send_ok ? 'sent' : 'failed',
];
$to_log = $log_event + [
    'form' => redact([
        'name' => $user_name,
        'email' => $user_email,
        'message_len' => strlen($message),
    ], $log_redact),
];
log_json_line($log_file, $to_log);

if ($send_ok) {
    json_resp(200, ['ok'=>true]);
} else {
    $err = $api_result['err'] ?? ($smtp_result['err'] ?? 'send_failed');
    json_resp(500, ['ok'=>false,'error'=>$err]);
}
