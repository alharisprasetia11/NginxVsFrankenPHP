<?php
ignore_user_abort(true);

function fib($n)
{
    if ($n < 0) return 0;
    if ($n < 2) return $n;
    return fib($n - 1) + fib($n - 2);
}

function getDB()
{
    static $pdo;

    if ($pdo) {
        return $pdo;
    }

    $host = 'db';
    $db   = 'myapp';
    $user = 'myuser';
    $pass = 'mypassword';
    $charset = 'utf8mb4';

    $dsn = "mysql:host=$host;dbname=$db;charset=$charset";
    $options = [
        PDO::ATTR_ERRMODE            => PDO::ERRMODE_EXCEPTION,
        PDO::ATTR_DEFAULT_FETCH_MODE => PDO::FETCH_ASSOC,
        PDO::ATTR_EMULATE_PREPARES   => false,
        PDO::ATTR_PERSISTENT         => true,
    ];

    try {
        $pdo = new PDO($dsn, $user, $pass, $options);
        return $pdo;
    } catch (\PDOException $e) {
        throw $e;
    }
}

function myAppLogic()
{
    header('Content-Type: application/json');

    $action = $_GET['action'] ?? 'hello';

    switch ($action) {
        case 'cpu':
            $result = fib(25);
            echo json_encode([
                'status' => 'ok',
                'server' => $_SERVER['SERVER_SOFTWARE'] ?? 'FrankenPHP',
                'result' => $result
            ]);
            break;

        case 'io':
            $file = sys_get_temp_dir() . '/test_' . uniqid() . '.tmp';
            file_put_contents($file, str_repeat('IO Test Data ', 100));
            $content = file_get_contents($file);
            unlink($file);
            echo json_encode(['status' => 'ok', 'server' => $_SERVER['SERVER_SOFTWARE'] ?? 'FrankenPHP']);
            break;

        case 'db':
            try {
                $pdo = getDB();

                $stmt = $pdo->query("SELECT id, nama, nim FROM users LIMIT 50");
                $data = $stmt->fetchAll();

                echo json_encode([
                    'status' => 'ok',
                    'server' => $_SERVER['SERVER_SOFTWARE'] ?? 'FrankenPHP',
                    'count' => count($data),
                    'data' => $data
                ]);
            } catch (\Exception $e) {
                http_response_code(500);
                echo json_encode([
                    'status' => 'error',
                    'message' => 'DB Error: ' . $e->getMessage()
                ]);
            }
            break;

        case 'hello':
        default:
            header('Content-Type: text/html');
            if (file_exists('web.php')) {
                include 'web.php';
            } else {
                echo "<h1>Hello World</h1>";
            }
            break;
    }
}

$workerAvailable = function_exists('frankenphp_handle_request');

if ($workerAvailable) {
    try { getDB(); } catch (Exception $e) {}

    $nbRequests = 0;
    do {
        $running = \frankenphp_handle_request(function () {
            myAppLogic();
        });

        if (++$nbRequests > 500) {
            gc_collect_cycles();
            $nbRequests = 0;
        }
    } while ($running);
} else {
    myAppLogic();
}