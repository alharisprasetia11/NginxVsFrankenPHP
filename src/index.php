<?php
declare(strict_types=1);

ignore_user_abort(true);

/**
 * Aplikasi benchmark. Mode dipilih lewat env APP_MODE:
 *   fpm     -> PHP-FPM di belakang Nginx
 *   classic -> FrankenPHP tanpa worker (script dijalankan per request)
 *   worker  -> FrankenPHP worker mode (script hidup terus, loop request)
 */

function fib(int $n): int
{
    if ($n < 2) {
        return $n < 0 ? 0 : $n;
    }
    return fib($n - 1) + fib($n - 2);
}

/** Koneksi PDO; $reset=true membuang koneksi lama (non-persistent) untuk reconnect. */
function pdo(bool $reset = false): PDO
{
    static $pdo = null;

    if ($reset) {
        $pdo = null;
    }
    if ($pdo !== null) {
        return $pdo;
    }

    $options = [
        PDO::ATTR_ERRMODE            => PDO::ERRMODE_EXCEPTION,
        PDO::ATTR_DEFAULT_FETCH_MODE => PDO::FETCH_ASSOC,
        PDO::ATTR_EMULATE_PREPARES   => false,
        PDO::ATTR_PERSISTENT         => !$reset,
        PDO::ATTR_TIMEOUT            => 5,
    ];

    return $pdo = new PDO('mysql:host=db;dbname=myapp;charset=utf8mb4', 'myuser', 'mypassword', $options);
}

/** Jalankan query dan reconnect SEKALI bila koneksi putus (mis. MySQL restart). */
function withDb(callable $fn): mixed
{
    try {
        return $fn(pdo());
    } catch (PDOException $e) {
        $code = (int) ($e->errorInfo[1] ?? 0);
        if (in_array($code, [2002, 2006, 2013], true) || str_contains($e->getMessage(), 'gone away')) {
            return $fn(pdo(true));
        }
        throw $e;
    }
}

function respond(array $payload, int $status = 200): void
{
    http_response_code($status);
    header('Content-Type: application/json');
    echo json_encode(
        $payload + [
            'server' => $_SERVER['SERVER_SOFTWARE'] ?? 'unknown',
            'mode'   => getenv('APP_MODE') ?: 'fpm',
        ]
    );
}

function handleRequest(): void
{
    static $served = 0;
    $served++;

    $action = (string) ($_GET['action'] ?? 'hello');

    try {
        switch ($action) {
            case 'health':
                respond(['status' => 'ok']);
                break;

            case 'cpu':
                $n = max(1, min(30, (int) ($_GET['n'] ?? 25)));
                respond(['status' => 'ok', 'result' => fib($n)]);
                break;

            case 'io':
                $file = sys_get_temp_dir() . '/test_' . bin2hex(random_bytes(8)) . '.tmp';
                file_put_contents($file, str_repeat('IO Test Data ', 100));
                $content = file_get_contents($file);
                unlink($file);
                respond(['status' => 'ok', 'bytes' => strlen((string) $content)]);
                break;

            case 'db':
                $data = withDb(static fn (PDO $db) => $db->query('SELECT id, nama, nim FROM users LIMIT 50')->fetchAll());
                respond(['status' => 'ok', 'count' => count($data), 'data' => $data]);
                break;

            case 'dbwrite':
                $id = withDb(static function (PDO $db) {
                    $st = $db->prepare('INSERT INTO bench_log (payload, created_at) VALUES (?, NOW(6))');
                    $st->execute([bin2hex(random_bytes(32))]);
                    return (int) $db->lastInsertId();
                });
                respond(['status' => 'ok', 'id' => $id]);
                break;

            case 'slow':
                // Simulasi dependensi eksternal yang lambat (default 100 ms, maks 2000 ms)
                $ms = max(0, min(2000, (int) ($_GET['ms'] ?? 100)));
                usleep($ms * 1000);
                respond(['status' => 'ok', 'slept_ms' => $ms]);
                break;

            case 'stats':
                // Dipakai untuk memantau memori per proses/worker saat soak test
                respond([
                    'status'      => 'ok',
                    'pid'         => getmypid(),
                    'served'      => $served,
                    'mem_bytes'   => memory_get_usage(true),
                    'mem_peak'    => memory_get_peak_usage(true),
                ]);
                break;

            case 'hello':
            default:
                header('Content-Type: text/html');
                require __DIR__ . '/web.php';
                break;
        }
    } catch (Throwable $e) {
        // Jangan sampai exception mematikan worker
        respond(['status' => 'error', 'message' => get_class($e) . ': ' . $e->getMessage()], 500);
    }
}

if ((getenv('APP_MODE') ?: 'fpm') === 'worker') {
    if (!function_exists('frankenphp_handle_request')) {
        fwrite(STDERR, "APP_MODE=worker tetapi bukan FrankenPHP worker\n");
        exit(1);
    }

    try {
        pdo(); // pre-warm koneksi
    } catch (Throwable) {
    }

    $handler = static function (): void {
        handleRequest();
    };

    $count = 0;
    while (frankenphp_handle_request($handler)) {
        if (++$count % 500 === 0) {
            gc_collect_cycles();
        }
    }
} else {
    handleRequest();
}
