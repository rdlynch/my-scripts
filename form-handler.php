<?php
/**
 * Universal Form Handler for Alpha Omega Strategies
 * Handles forms with Postmark email and Backblaze B2 logging
 * WCAG 2.2 AA Compliant
 */

// Error reporting for development (disable in production)
error_reporting(E_ALL);
ini_set('display_errors', 1);

// Security headers
header('X-Content-Type-Options: nosniff');
header('X-Frame-Options: DENY');
header('X-XSS-Protection: 1; mode=block');

// Configuration
$config = [
    'postmark_token' => '', // Set your Postmark API token
    'b2_key_id' => '',      // Set your B2 Key ID
    'b2_app_key' => '',     // Set your B2 Application Key
    'b2_bucket' => '',      // Set your B2 bucket name
    'b2_endpoint' => '',    // Set your B2 endpoint URL
    'max_file_size' => 5 * 1024 * 1024, // 5MB
    'allowed_types' => ['pdf', 'doc', 'docx', 'txt', 'jpg', 'jpeg', 'png'],
    'log_dir' => '/var/log/forms'
];

// Load configuration from secure file
if (file_exists('/root/.form-secrets')) {
    $secrets = parse_ini_file('/root/.form-secrets');
    $config = array_merge($config, $secrets);
}

// Validate configuration
if (empty($config['postmark_token']) && empty($config['b2_key_id'])) {
    error_log('Form handler: No API credentials configured');
    http_response_code(503);
    echo json_encode(['success' => false, 'message' => 'Service temporarily unavailable']);
    exit;
}

/**
 * Sanitize input data
 */
function sanitizeInput($data) {
    return htmlspecialchars(strip_tags(trim($data)), ENT_QUOTES, 'UTF-8');
}

/**
 * Validate email address
 */
function isValidEmail($email) {
    return filter_var($email, FILTER_VALIDATE_EMAIL) !== false;
}

/**
 * Log form submission
 */
function logSubmission($site, $data, $files = []) {
    global $config;
    
    $date = date('Y-m-d');
    $timestamp = date('Y-m-d H:i:s');
    $logDir = $config['log_dir'] . '/' . $site;
    
    if (!is_dir($logDir)) {
        mkdir($logDir, 0755, true);
    }
    
    $logFile = $logDir . '/' . $date . '.log';
    $logEntry = [
        'timestamp' => $timestamp,
        'ip' => $_SERVER['REMOTE_ADDR'] ?? 'unknown',
        'user_agent' => $_SERVER['HTTP_USER_AGENT'] ?? 'unknown',
        'form_data' => $data,
        'files' => $files
    ];
    
    file_put_contents($logFile, json_encode($logEntry) . "\n", FILE_APPEND | LOCK_EX);
}

/**
 * Upload file to Backblaze B2
 */
function uploadToB2($filePath, $fileName, $site) {
    global $config;
    
    if (empty($config['b2_key_id']) || empty($config['b2_app_key'])) {
        return false;
    }
    
    $date = date('Y-m-d');
    $b2Path = $site . '/' . $date . '/' . $fileName;
    
    // Simple B2 upload implementation
    // In production, consider using a proper B2 SDK
    $ch = curl_init();
    curl_setopt_array($ch, [
        CURLOPT_URL => $config['b2_endpoint'] . '/' . $config['b2_bucket'] . '/' . $b2Path,
        CURLOPT_RETURNTRANSFER => true,
        CURLOPT_POST => true,
        CURLOPT_POSTFIELDS => file_get_contents($filePath),
        CURLOPT_HTTPHEADER => [
            'Authorization: Basic ' . base64_encode($config['b2_key_id'] . ':' . $config['b2_app_key']),
            'Content-Type: application/octet-stream'
        ]
    ]);
    
    $result = curl_exec($ch);
    $httpCode = curl_getinfo($ch, CURLINFO_HTTP_CODE);
    curl_close($ch);
    
    return $httpCode === 200;
}

/**
 * Send email via Postmark
 */
function sendPostmarkEmail($to, $subject, $htmlBody, $textBody, $attachments = []) {
    global $config;
    
    if (empty($config['postmark_token'])) {
        return false;
    }
    
    $data = [
        'From' => 'noreply@' . $_SERVER['HTTP_HOST'],
        'To' => $to,
        'Subject' => $subject,
        'HtmlBody' => $htmlBody,
        'TextBody' => $textBody,
        'MessageStream' => 'outbound'
    ];
    
    if (!empty($attachments)) {
        $data['Attachments'] = $attachments;
    }
    
    $ch = curl_init();
    curl_setopt_array($ch, [
        CURLOPT_URL => 'https://api.postmarkapp.com/email',
        CURLOPT_RETURNTRANSFER => true,
        CURLOPT_POST => true,
        CURLOPT_POSTFIELDS => json_encode($data),
        CURLOPT_HTTPHEADER => [
            'Accept: application/json',
            'Content-Type: application/json',
            'X-Postmark-Server-Token: ' . $config['postmark_token']
        ]
    ]);
    
    $result = curl_exec($ch);
    $httpCode = curl_getinfo($ch, CURLINFO_HTTP_CODE);
    curl_close($ch);
    
    return $httpCode === 200;
}

// Main form processing
if ($_SERVER['REQUEST_METHOD'] === 'POST') {
    $response = ['success' => false, 'message' => ''];
    
    try {
        // Get site name from referrer or form data
        $site = sanitizeInput($_POST['site'] ?? parse_url($_SERVER['HTTP_REFERER'] ?? '', PHP_URL_HOST) ?? 'unknown');
        
        // Validate required fields
        if (empty($_POST['email']) || !isValidEmail($_POST['email'])) {
            throw new Exception('Valid email address is required.');
        }
        
        // Sanitize form data
        $formData = [];
        foreach ($_POST as $key => $value) {
            if ($key !== 'site') {
                $formData[$key] = sanitizeInput($value);
            }
        }
        
        // Handle file uploads
        $uploadedFiles = [];
        if (!empty($_FILES)) {
            foreach ($_FILES as $fieldName => $file) {
                if ($file['error'] === UPLOAD_ERR_OK) {
                    // Validate file
                    if ($file['size'] > $config['max_file_size']) {
                        throw new Exception('File size exceeds 5MB limit.');
                    }
                    
                    $extension = strtolower(pathinfo($file['name'], PATHINFO_EXTENSION));
                    if (!in_array($extension, $config['allowed_types'])) {
                        throw new Exception('File type not allowed.');
                    }
                    
                    // Generate secure filename
                    $fileName = date('Y-m-d_H-i-s') . '_' . bin2hex(random_bytes(8)) . '.' . $extension;
                    $tempPath = $file['tmp_name'];
                    
                    // Upload to B2
                    if (uploadToB2($tempPath, $fileName, $site)) {
                        $uploadedFiles[] = [
                            'original_name' => $file['name'],
                            'stored_name' => $fileName,
                            'size' => $file['size']
                        ];
                    }
                }
            }
        }
        
        // Log the submission
        logSubmission($site, $formData, $uploadedFiles);
        
        // Prepare email content
        $subject = 'New Form Submission from ' . $site;
        $htmlBody = '<h2>New Form Submission</h2>';
        $textBody = "New Form Submission\n\n";
        
        foreach ($formData as $key => $value) {
            $label = ucwords(str_replace(['_', '-'], ' ', $key));
            $htmlBody .= '<p><strong>' . $label . ':</strong> ' . htmlspecialchars($value) . '</p>';
            $textBody .= $label . ': ' . $value . "\n";
        }
        
        if (!empty($uploadedFiles)) {
            $htmlBody .= '<h3>Uploaded Files:</h3><ul>';
            $textBody .= "\nUploaded Files:\n";
            
            foreach ($uploadedFiles as $file) {
                $htmlBody .= '<li>' . htmlspecialchars($file['original_name']) . ' (' . number_format($file['size'] / 1024, 2) . ' KB)</li>';
                $textBody .= '- ' . $file['original_name'] . ' (' . number_format($file['size'] / 1024, 2) . ' KB)' . "\n";
            }
            
            $htmlBody .= '</ul>';
        }
        
        // Send email
        $emailSent = sendPostmarkEmail(
            $formData['email'],
            $subject,
            $htmlBody,
            $textBody
        );
        
        if ($emailSent) {
            $response['success'] = true;
            $response['message'] = 'Thank you! Your submission has been received.';
        } else {
            $response['message'] = 'Form submitted but email notification failed.';
        }
        
    } catch (Exception $e) {
        $response['message'] = $e->getMessage();
        error_log('Form handler error: ' . $e->getMessage());
    }
    
    // Return JSON response
    header('Content-Type: application/json');
    echo json_encode($response);
    exit;
}

// If not POST, return method not allowed
http_response_code(405);
echo json_encode(['success' => false, 'message' => 'Method not allowed']);
?>
