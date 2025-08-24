<?php
/**
 * AOS Simple Form Handler
 * - One config file for all domains: /etc/aos-form-secrets (INI)
 * - HTTP API to Postmark by default with SMTP fallback
 * - Anti-abuse: honeypot, min submit time, IP rate limit, optional CAPTCHA
 * - Clear JSON responses and structured logs in /var/log/forms
 */

declare(strict_types=1);
set_time_limit(10);

// Allow CORS preflight for fetch-based forms while keeping same-origin rules
if ($_SERVER['REQUEST_METHOD'] === 'OPTIONS') {
    $host = strtolower(preg_replace('/:\d+$/', '', $_SERVER['HTTP_HOST'] ?? ''));
    $origin = $_SERVER['HTTP_ORIGIN'] ?? '';
    if ($origin !== '' && parse_url($origin, PHP_URL_HOST) === $host) {
        header('Access-Control-Allow-Origin: ' . $origin);
        header('Vary: Origin');
        header('Access-Control-Allow-Methods: POST, OPTIONS');
        header('Access-Control-Allow-Headers: Content-Type');
    }
    http_response_code(204);
    exit;
}

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

// Pull settings once. No per-domain overrides.
$app    = $cfg['app']      ?? [];
$smtp   = $cfg['smtp']     ?? [];
$sec    = $cfg['security'] ?? [];
$logcfg = $cfg['logging']  ?? [];

// App settings
$site_name   = $app['site_name'] ?? 'Website';
$from_name   = $app['from_name'] ?? ($site_name . ' Contact');
$from_email  = $app['from_email'] ?? ('no-reply@' . (strtolower(preg_replace('/:\d+$/', '', $_SERVER['HTTP_HOST'] ?? 'localhost'))));
$prefix      = trim((string)($app['subject_prefix'] ?? ''));
$prefix      = $prefix ? ($prefix . ' ') : '';
$to          = array_filter(array_map('trim', explode(',', (string)($app['to'] ?? ''))));
$cc          = array_filter(array_map('trim', explode(',', (string)($app['cc'] ?? ''))));
$bcc         = array_filter(array_map('trim', explode(',', (string)($app['bcc'] ?? ''))));

// Transport defaults
$transport     = strtolower((string)($smtp['transport'] ?? 'api')); // api or smtp
$smtp_host     = $smtp['host'] ?? 'smtp.postmarkapp.com';
$smtp_port     = (int)($smtp['port'] ?? 587);
$smtp_user     = $smtp['username'] ?? '';
$smtp_pass     = $smtp['password'] ?? '';
$smtp_enc      = strtolower((string)($smtp['encryption'] ?? 'tls'));
$smtp_timeout  = (int)($smtp['timeout'] ?? 15);
$message_stream = (string)($smtp['message_stream'] ?? 'outbound');

// Security
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

// Logging
$log_file   = $logcfg['log_file'] ?? '/var/log/forms/contact.log';
$log_redact = array_filter(array_map('trim', explode(',', (string)($logcfg['log_redact_fields'] ?? 'password,token,csrf,captcha,attachment'))));

// Paths
$rate_dir = '/var/cache/aos-forms';
if (!is_dir($rate_dir)) { @mkdir($rate_dir, 02770, true); @chgrp($rate_dir, 'www-data'); }

// Helpers
function json_resp(int $code, array $payload): void {
    http_response_code($code);
    header('Content-Type: application/json; charset=utf-8');
    echo json_encode($payload, JSON_UNESCAPED_SLASHES);
    exit;
}
function log_json_line(string $file, array $event, array $redact = []): void {
    $event['ts'] = time();
    foreach ($redact as $k) { if (array_key_exists($k, $event)) $event[$k] = '[REDACTED]'; }
    @file_put_contents($file, json_encode($event, JSON_UNESCAPED_SLASHES) . PHP_EOL, FILE_APPEND | LOCK_EX);
    @chmod($file, 0640); @chgrp($file, 'www-data');
}
function client_ip(): string { return $_SERVER['REMOTE_ADDR'] ?? '0.0.0.0'; }
function clean_text(string $s, int $max): string {
    $s = trim(str_replace(["\r\n", "\r"], "\n", $s));
    $s = preg_replace('/[[:^print:]\t]/u', '', $s);
    if (mb_strlen($s, 'UTF-8') > $max) $s = mb_substr($s, 0, $max, 'UTF-8');
    return $s;
}
// Auto same-origin guard: if Origin is present it must match Host; else if Referer present its host must match Host; else allow
function same_origin_ok(): bool {
    $host = strtolower(preg_replace('/:\d+$/', '', $_SERVER['HTTP_HOST'] ?? ''));
    $origin = $_SERVER['HTTP_ORIGIN'] ?? '';
    $referer = $_SERVER['HTTP_REFERER'] ?? '';
    if ($origin !== '') {
        return parse_url($origin, PHP_URL_HOST) === $host;
    }
    if ($referer !== '') {
        return parse_url($referer, PHP_URL_HOST) === $host;
    }
    return true;
}
function too_fast(?string $ts, int $min): bool {
    if (!$ts || !ctype_digit($ts)) return false;
    return (time() - (int)$ts) < $min;
}
function rate_check(string $ip, string $dir, int $window, int $max): bool {
    $file = $dir . '/rl_' . preg_replace('/[^0-9a-fA-F:.]/', '_', $ip) . '.json';
    $now = time();
    $data = ['start'=>$now,'count'=>0];
    if (is_file($file)) {
        $raw = @file_get_contents($file);
        if ($raw) $data = json_decode($raw, true) ?: $data;
        if (($now - ($data['start'] ?? $now)) > $window) $data = ['start'=>$now,'count'=>0];
    }
    $data['count'] = (int)($data['count'] ?? 0) + 1;
    @file_put_contents($file, json_encode($data), LOCK_EX);
    @chmod($file, 0660); @chgrp($file, 'www-data');
    return $data['count'] <= $max;
}
function is_disposable_email(string $email): bool {
    $parts = explode('@', strtolower($email));
    if (count($parts) !== 2) return true;
    if (!filter_var($email, FILTER_VALIDATE_EMAIL)) return true;
    $domain = $parts[1];
    foreach (['mailinator.com','10minutemail.','yopmail.com','guerrillamail.','dropmail.','tempmail.','trashmail.'] as $pat) {
        if (str_contains($domain, $pat)) return true;
    }
    return false;
}
function verify_captcha(string $provider, string $secret, string $token, string $ip): bool {
    if ($provider === 'none' || $provider === '' || $token === '' || $secret === '') return true;
    $endpoints = [
        'turnstile' => 'https://challenges.cloudflare.com/turnstile/v0/siteverify',
        'hcaptcha'  => 'https://hcaptcha.com/siteverify',
        'recaptcha' => 'https://www.google.com/recaptcha/api/siteverify',
    ];
    $url = $endpoints[$provider] ?? ''; if ($url === '') return false;
    $ch = curl_init($url);
    curl_setopt_array($ch, [
        CURLOPT_RETURNTRANSFER => true,
        CURLOPT_POST => true,
        CURLOPT_POSTFIELDS => http_build_query(['secret'=>$secret, 'response'=>$token, 'remoteip'=>$ip]),
        CURLOPT_TIMEOUT => 8,
        CURLOPT_HTTPHEADER => ['Content-Type: application/x-www-form-urlencoded'],
    ]);
    $resp = curl_exec($ch); $code = curl_getinfo($ch, CURLINFO_RESPONSE_CODE); curl_close($ch);
    if ($resp === false || $code !== 200) return false;
    $json = json_decode($resp, true); return is_array($json) && !empty($json['success']);
}
function postmark_api_send(array $payload, string $server_token): array {
    $ch = curl_init('https://api.postmarkapp.com/email');
    curl_setopt_array($ch, [
        CURLOPT_RETURNTRANSFER => true,
        CURLOPT_POST => true,
        CURLOPT_POSTFIELDS => json_encode($payload, JSON_UNESCAPED_SLASHES),
        CURLOPT_TIMEOUT => 10,
        CURLOPT_HTTPHEADER => ['Accept: application/json','Content-Type: application/json','X-Postmark-Server-Token: '.$server_token],
    ]);
    $resp = curl_exec($ch); $err = curl_error($ch); $info = curl_getinfo($ch); curl_close($ch);
    return ['ok' => ($info['http_code'] ?? 0) >= 200 && ($info['http_code'] ?? 0) < 300, 'code'=>$info['http_code'] ?? 0, 'body'=>$resp, 'err'=>$err];
}
function smtp_send_simple(array $msg, string $host, int $port, string $enc, string $user, string $pass, int $timeout): array {
    $fp = @stream_socket_client("tcp://{$host}:{$port}", $errno, $errstr, $timeout, STREAM_CLIENT_CONNECT);
    if (!$fp) return ['ok'=>false,'err'=>"connect: $errstr"];
    stream_set_timeout($fp, $timeout);
    $r = fn() => fgets($fp, 512);
    $w = fn($l) => fwrite($fp, $l . "\r\n");
    if (strpos($r(), '220') !== 0) return ['ok'=>false,'err'=>'no 220'];
    $w('EHLO client.example'); while (($l=$r()) && !preg_match('/^\d{3} /',$l)) {}
    $w('STARTTLS'); if (strpos($r(), '220') !== 0) return ['ok'=>false,'err'=>'starttls'];
    if (!stream_socket_enable_crypto($fp, true, STREAM_CRYPTO_METHOD_TLS_CLIENT)) return ['ok'=>false,'err'=>'tls'];
    $w('EHLO client.example'); while (($l=$r()) && !preg_match('/^\d{3} /',$l)) {}
    $auth = base64_encode("\0{$user}\0{$pass}");
    $w('AUTH PLAIN ' . $auth); if (strpos($r(), '235') !== 0) return ['ok'=>false,'err'=>'auth'];
    $w('MAIL FROM:<'.$msg['from'].'>'); if (strpos($r(), '250') !== 0) return ['ok'=>false,'err'=>'mailfrom'];
    $rcpts = array_values(array_unique(array_merge([$msg['to']], $msg['cc'], $msg['bcc'])));
    foreach ($rcpts as $rcp) { $w('RCPT TO:<'.$rcp.'>'); if (strpos($r(), '250') !== 0) return ['ok'=>false,'err'=>'rcpt']; }
    $w('DATA'); if (strpos($r(), '354') !== 0) return ['ok'=>false,'err'=>'data'];
    $h = [];
    $h[] = 'Date: ' . gmdate('D, d M Y H:i:s') . ' +0000';
    $h[] = 'From: ' . $msg['from_name'] . ' <' . $msg['from'] . '>';
    $h[] = 'To: ' . $msg['to'];
    if (!empty($msg['cc'])) $h[] = 'Cc: ' . implode(', ', $msg['cc']);
    $h[] = 'Subject: ' . $msg['subject'];
    $h[] = 'MIME-Version: 1.0';
    $h[] = 'X-PM-Message-Stream: ' . ($msg['message_stream'] ?? 'outbound');
    if (!empty($msg['reply_to'])) $h[] = 'Reply-To: ' . $msg['reply_to'];
    $h[] = 'Content-Type: text/plain; charset=UTF-8';
    $mime = implode("\r\n", $h) . "\r\n\r\n" . $msg['text'] . "\r\n.";
    $w($mime); if (strpos($r(), '250') !== 0) return ['ok'=>false,'err'=>'not_accepted'];
    $w('QUIT'); $r(); fclose($fp); return ['ok'=>true];
}

// Input
$ip = client_ip();
$host = strtolower(preg_replace('/:\d+$/', '', $_SERVER['HTTP_HOST'] ?? ''));
$origin_ok = same_origin_ok();
$in = $_POST;

$user_email = clean_text((string)($in['email'] ?? ''), 320);
$user_name  = clean_text((string)($in['name'] ?? ''), 200);
$message    = clean_text((string)($in['message'] ?? ''), $max_body_chars);
$ts_field   = (string)($in['ts'] ?? '');
$hp_value   = (string)($in[$honeypot_field] ?? '');

// Guard rails
if (!$origin_ok) {
    log_json_line($log_file, ['evt'=>'forbidden_origin','host'=>$host,'ip'=>$ip,'origin'=>($_SERVER['HTTP_ORIGIN'] ?? ''),'referer'=>($_SERVER['HTTP_REFERER'] ?? '')], []);
    json_resp(403, ['ok'=>false,'error'=>'forbidden']);
}
if ($hp_value !== '') { log_json_line($log_file, ['evt'=>'honeypot','ip'=>$ip], []); json_resp(200, ['ok'=>true]); }
if (too_fast($ts_field, $min_submit_seconds)) { log_json_line($log_file, ['evt'=>'too_fast','ip'=>$ip], []); json_resp(429, ['ok'=>false,'error'=>'too_fast']); }
if (!rate_check($ip, $rate_dir, $rate_window, $rate_max)) { log_json_line($log_file, ['evt'=>'rate_limit','ip'=>$ip], []); json_resp(429, ['ok'=>false,'error'=>'rate_limited']); }
if ($user_email === '' || !filter_var($user_email, FILTER_VALIDATE_EMAIL)) { json_resp(400, ['ok'=>false,'error'=>'invalid_email']); }
if ($block_disposable && is_disposable_email($user_email)) { json_resp(400, ['ok'=>false,'error'=>'disposable_email_blocked']); }
if ($message === '') { json_resp(400, ['ok'=>false,'error'=>'empty_message']); }

// Optional CAPTCHA
$captcha_token = (string)($in['captcha'] ?? $in['cf-turnstile-response'] ?? $in['h-captcha-response'] ?? $in['g-recaptcha-response'] ?? '');
if (!verify_captcha($captcha_provider, $captcha_secret, $captcha_token, $ip)) {
    log_json_line($log_file, ['evt'=>'captcha_fail','ip'=>$ip,'provider'=>$captcha_provider], []);
    json_resp(403, ['ok'=>false,'error'=>'captcha_failed']);
}

// Attachments
$attachments_api = [];
if (!empty($_FILES)) {
    $total = 0;
    foreach ($_FILES as $file) {
        if (($file['error'] ?? UPLOAD_ERR_NO_FILE) === UPLOAD_ERR_NO_FILE) continue;
        if (($file['error'] ?? UPLOAD_ERR_OK) !== UPLOAD_ERR_OK) json_resp(400, ['ok'=>false,'error'=>'attachment_error']);
        $name = (string)$file['name']; $size = (int)$file['size']; $tmp = (string)$file['tmp_name'];
        $ext = strtolower(pathinfo($name, PATHINFO_EXTENSION));
        if (!in_array($ext, $allowed_attachs, true)) json_resp(400, ['ok'=>false,'error'=>'attachment_type']);
        $total += $size; if ($total > ($max_attach_mb * 1024 * 1024)) json_resp(400, ['ok'=>false,'error'=>'attachment_too_large']);
        $mime = mime_content_type($tmp) ?: 'application/octet-stream';
        $attachments_api[] = ['Name'=>$name,'Content'=>base64_encode(file_get_contents($tmp)),'ContentType'=>$mime];
    }
}

// Build message
$subject = $prefix . 'New message from ' . ($user_name !== '' ? $user_name : $user_email) . ' [' . $host . ']';
$lines = [];
$lines[] = "From: " . ($user_name !== '' ? "$user_name <$user_email>" : $user_email);
$lines[] = "Site: $host";
$lines[] = "IP: $ip";
$lines[] = "Time (UTC): " . gmdate('Y-m-d H:i:s');
$lines[] = str_repeat('-', 40);
$lines[] = $message;
$text_body = implode("\n", $lines);

$primary_to = $to[0] ?? '';
if ($primary_to === '') json_resp(500, ['ok'=>false,'error'=>'recipient_missing']);

$payload = [
    'From' => sprintf('%s <%s>', $from_name, $from_email),
    'To' => implode(',', $to),
    'Cc' => implode(',', $cc),
    'Bcc' => implode(',', $bcc),
    'Subject' => $subject,
    'TextBody' => $text_body,
    'MessageStream' => $message_stream,
    'ReplyTo' => $user_email,
    'Headers' => [
        ['Name'=>'X-PM-Tag','Value'=>'contact'],
        ['Name'=>'X-AOS-Site','Value'=>$site_name],
        ['Name'=>'X-Origin-Host','Value'=>$host],
    ],
];
if ($attachments_api) $payload['Attachments'] = $attachments_api;

// Send: API first, SMTP fallback
$send_ok = false; $api_result = null; $smtp_result = null;
if ($transport !== 'smtp') {
    $api_result = postmark_api_send($payload, $smtp_user ?: $smtp_pass);
    $send_ok = $api_result['ok'] ?? false;
}
if (!$send_ok) {
    $smtp_msg = [
        'from' => $from_email, 'from_name' => $from_name,
        'to' => $primary_to, 'cc' => $cc, 'bcc' => $bcc,
        'subject' => $subject, 'text' => $text_body,
        'reply_to' => $user_email, 'message_stream' => $message_stream,
    ];
    $user_eff = $smtp_user ?: $smtp_pass; $pass_eff = $smtp_pass ?: $smtp_user;
    $smtp_result = smtp_send_simple($smtp_msg, $smtp_host, $smtp_port, $smtp_enc, $user_eff, $pass_eff, $smtp_timeout);
    $send_ok = $smtp_result['ok'] ?? false;
}

// Log and respond
$evt = ['evt'=>'submit','host'=>$host,'ip'=>$ip,'transport'=>$send_ok ? (($api_result && ($api_result['ok']??false)) ? 'api' : 'smtp') : 'none','status'=>$send_ok?'sent':'failed'];
log_json_line($log_file, $evt, $log_redact);

if ($send_ok) {
    // CORS success echo for fetch-based forms
    $origin = $_SERVER['HTTP_ORIGIN'] ?? '';
    if ($origin !== '' && parse_url($origin, PHP_URL_HOST) === $host) { header('Access-Control-Allow-Origin: ' . $origin); header('Vary: Origin'); }
    json_resp(200, ['ok'=>true]);
} else {
    $err = $api_result['err'] ?? ($smtp_result['err'] ?? 'send_failed');
    json_resp(500, ['ok'=>false,'error'=>$err]);
}
