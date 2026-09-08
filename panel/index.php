<?php
declare(strict_types=1);

session_name('NONECDNSESSID');

session_save_path(
    '/var/lib/nonecdn/state/sessions'
);

session_start([
    'cookie_httponly' => true,
    'cookie_samesite' => 'Strict',
    'use_strict_mode' => true,
]);

require '/opt/nonecdn/src/autoload.php';

use NoneCDN\Auth\Auth;
use NoneCDN\Config\Settings;
use NoneCDN\Core\Bootstrap;
use NoneCDN\Database\Database;
use NoneCDN\Panel\Csrf;
use NoneCDN\Source\SourceManager;

$db = new Database(
    Bootstrap::DB_PATH
);

$settings = new Settings($db);
$sources = new SourceManager($db);

function e(mixed $v): string
{
    return htmlspecialchars(
        (string)$v,
        ENT_QUOTES,
        'UTF-8'
    );
}

function redirect(string $to): never
{
    header('Location: ' . $to);
    exit;
}

function flash(
    string $type,
    string $message
): void {
    $_SESSION['flash'] = [
        'type' => $type,
        'message' => $message,
    ];
}

function layoutStart(string $title): void
{
    $safe = e($title);

    echo <<<HTML
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport"
 content="width=device-width,initial-scale=1">
<title>{$safe}</title>
<style>
body{
 font-family:system-ui,sans-serif;
 margin:0;background:#f5f6f8;color:#1d2733
}
header{
 background:#111827;color:white;
 padding:14px 20px;
 display:flex;justify-content:space-between;
 align-items:center
}
nav a{
 color:white;text-decoration:none;
 margin-right:16px
}
main{max-width:1200px;margin:20px auto;padding:0 14px}
.card{
 background:white;border-radius:10px;
 padding:18px;margin-bottom:16px;
 box-shadow:0 1px 4px #0001
}
.grid{
 display:grid;
 grid-template-columns:repeat(auto-fit,minmax(180px,1fr));
 gap:12px
}
.stat{
 background:white;border-radius:10px;
 padding:16px
}
input,select,textarea{
 width:100%;box-sizing:border-box;
 padding:9px;margin:5px 0 12px;
 border:1px solid #ccd2da;border-radius:7px
}
button,.btn{
 border:0;background:#2563eb;color:white;
 padding:9px 14px;border-radius:7px;
 text-decoration:none;cursor:pointer
}
.danger{background:#dc2626}
.secondary{background:#64748b}
table{
 width:100%;border-collapse:collapse
}
th,td{
 text-align:left;padding:10px;
 border-bottom:1px solid #e5e7eb;
 vertical-align:top
}
.ok{color:#15803d}
.bad{color:#b91c1c}
.flash{
 padding:12px;border-radius:8px;
 margin-bottom:14px;background:#e0f2fe
}
small{color:#64748b}
.actions{display:flex;gap:6px;flex-wrap:wrap}
</style>
</head>
<body>
HTML;

    if (Auth::check()) {
        echo '<header>';
        echo '<strong>NoneCDN</strong>';
        echo '<nav>';
        echo '<a href="/">Dashboard</a>';
        echo '<a href="/?page=sources">Sources</a>';
        echo '<a href="/?page=settings">Settings</a>';
        echo '<a href="/?page=logout">Logout</a>';
        echo '</nav></header>';
    }

    echo '<main>';

    if (!empty($_SESSION['flash'])) {
        $f = $_SESSION['flash'];
        unset($_SESSION['flash']);

        echo '<div class="flash">' .
             e($f['message']) .
             '</div>';
    }
}

function layoutEnd(): void
{
    echo '</main></body></html>';
}

$page = $_GET['page'] ?? 'dashboard';

if (!Auth::initialized()) {
    http_response_code(503);
    exit('Panel password is not initialized.');
}

if ($page === 'logout') {
    Auth::logout();
    redirect('/');
}

if (!Auth::check()) {
    if ($_SERVER['REQUEST_METHOD'] === 'POST') {
        $password =
            (string)($_POST['password'] ?? '');

        if (Auth::verify($password)) {
            Auth::login();
            redirect('/');
        }

        $error = 'Invalid password.';
    }

    layoutStart('Login');

    echo '<div class="card" style="max-width:420px;margin:60px auto">';
    echo '<h2>NoneCDN Login</h2>';

    if (!empty($error)) {
        echo '<p class="bad">' .
             e($error) .
             '</p>';
    }

    echo '<form method="post">';
    echo '<label>Password</label>';
    echo '<input type="password" name="password" required autofocus>';
    echo '<button type="submit">Login</button>';
    echo '</form></div>';

    layoutEnd();
    exit;
}

if (
    $_SERVER['REQUEST_METHOD'] === 'POST' &&
    !Csrf::validate(
        $_POST['csrf'] ?? null
    )
) {
    http_response_code(403);
    exit('Invalid CSRF token');
}

if ($page === 'settings') {
    if ($_SERVER['REQUEST_METHOD'] === 'POST') {
        $interval = max(
            1,
            (int)($_POST[
                'fetch_interval_seconds'
            ] ?? 10)
        );

        $ttlMinutes = max(
            1,
            (int)($_POST[
                'ttl_minutes'
            ] ?? 60)
        );

        $timeout = max(
            1,
            (int)($_POST[
                'request_timeout_seconds'
            ] ?? 7)
        );

        $parallel = max(
            1,
            min(
                500,
                (int)($_POST[
                    'max_parallel'
                ] ?? 50)
            )
        );

        $settings->set(
            'fetch.interval_seconds',
            $interval
        );

        $settings->set(
            'config.default_ttl_seconds',
            $ttlMinutes * 60
        );

        $settings->set(
            'fetch.request_timeout_seconds',
            $timeout
        );

        $settings->set(
            'fetch.max_parallel',
            $parallel
        );

        $settings->set(
            'fetcher.enabled',
            isset($_POST['fetcher_enabled'])
        );

        flash(
            'success',
            'Settings saved.'
        );

        redirect('/?page=settings');
    }

    layoutStart('Settings');

    $interval = $settings->get(
        'fetch.interval_seconds',
        10
    );

    $ttl = (int)round(
        $settings->get(
            'config.default_ttl_seconds',
            3600
        ) / 60
    );

    $timeout = $settings->get(
        'fetch.request_timeout_seconds',
        7
    );

    $parallel = $settings->get(
        'fetch.max_parallel',
        50
    );

    $enabled = $settings->get(
        'fetcher.enabled',
        true
    );

    echo '<div class="card">';
    echo '<h2>Global settings</h2>';
    echo '<form method="post">';
    echo '<input type="hidden" name="csrf" value="' .
         e(Csrf::token()) . '">';

    echo '<label>Global fetch interval (seconds)</label>';
    echo '<input type="number" min="1" name="fetch_interval_seconds" value="' .
         e($interval) . '">';

    echo '<label>Default config lifetime (minutes)</label>';
    echo '<input type="number" min="1" name="ttl_minutes" value="' .
         e($ttl) . '">';

    echo '<label>Request timeout (seconds)</label>';
    echo '<input type="number" min="1" name="request_timeout_seconds" value="' .
         e($timeout) . '">';

    echo '<label>Maximum parallel fetches</label>';
    echo '<input type="number" min="1" max="500" name="max_parallel" value="' .
         e($parallel) . '">';

    echo '<label>';
    echo '<input style="width:auto" type="checkbox" name="fetcher_enabled" ' .
         ($enabled ? 'checked' : '') . '>';
    echo ' Fetcher enabled';
    echo '</label><br><br>';

    echo '<button type="submit">Save settings</button>';
    echo '</form></div>';

    layoutEnd();
    exit;
}

if ($page === 'sources') {
    $action = $_GET['action'] ?? '';

    if (
        $_SERVER['REQUEST_METHOD'] === 'POST' &&
        $action === 'delete'
    ) {
        $id = (int)($_POST['id'] ?? 0);
        $sources->delete($id);

        flash('success', 'Source deleted.');
        redirect('/?page=sources');
    }

    if (
        $_SERVER['REQUEST_METHOD'] === 'POST' &&
        $action === 'toggle'
    ) {
        $id = (int)($_POST['id'] ?? 0);
        $row = $sources->find($id);

        if ($row) {
            $sources->update(
                $id,
                [
                    'enabled' =>
                        !(bool)$row['enabled']
                ]
            );
        }

        redirect('/?page=sources');
    }

    if (
        $_SERVER['REQUEST_METHOD'] === 'POST' &&
        in_array(
            $action,
            ['add','edit'],
            true
        )
    ) {
        $useGlobalInterval =
            isset($_POST[
                'use_global_interval'
            ]);

        $useGlobalTtl =
            isset($_POST[
                'use_global_ttl'
            ]);

        $headersText = trim(
            (string)($_POST[
                'custom_headers'
            ] ?? '')
        );

        $headers = [];

        if ($headersText !== '') {
            foreach (
                preg_split(
                    '/\R/',
                    $headersText
                ) as $line
            ) {
                $line = trim($line);

                if ($line !== '') {
                    $headers[] = $line;
                }
            }
        }

        $data = [
            'name' =>
                trim((string)$_POST['name']),
            'url' =>
                trim((string)$_POST['url']),
            'enabled' =>
                isset($_POST['enabled']),
            'use_global_interval' =>
                $useGlobalInterval,
            'fetch_interval_seconds' =>
                max(
                    1,
                    (int)($_POST[
                        'fetch_interval_seconds'
                    ] ?? 10)
                ),
            'use_global_ttl' =>
                $useGlobalTtl,
            'config_ttl_seconds' =>
                max(
                    60,
                    (int)($_POST[
                        'ttl_minutes'
                    ] ?? 60) * 60
                ),
            'request_timeout_seconds' =>
                max(
                    1,
                    (int)($_POST[
                        'request_timeout_seconds'
                    ] ?? 7)
                ),
            'verify_tls' =>
                isset($_POST['verify_tls']),
            'user_agent' =>
                trim(
                    (string)($_POST[
                        'user_agent'
                    ] ?? '')
                ) ?: null,
            'custom_headers' =>
                $headers,
        ];

        try {
            if ($action === 'add') {
                $sources->create($data);
                flash(
                    'success',
                    'Source added.'
                );
            } else {
                $id = (int)($_POST['id'] ?? 0);
                $sources->update(
                    $id,
                    $data
                );

                flash(
                    'success',
                    'Source updated.'
                );
            }
        } catch (\Throwable $e) {
            flash(
                'error',
                $e->getMessage()
            );
        }

        redirect('/?page=sources');
    }

    if (
        in_array(
            $action,
            ['add','edit'],
            true
        )
    ) {
        $row = [
            'id' => 0,
            'name' => '',
            'url' => '',
            'enabled' => 1,
            'use_global_interval' => 1,
            'fetch_interval_seconds' => 10,
            'use_global_ttl' => 1,
            'config_ttl_seconds' => 3600,
            'request_timeout_seconds' => 7,
            'verify_tls' => 1,
            'user_agent' => '',
            'custom_headers_json' => null,
        ];

        if ($action === 'edit') {
            $found = $sources->find(
                (int)($_GET['id'] ?? 0)
            );

            if (!$found) {
                http_response_code(404);
                exit('Source not found');
            }

            $row = $found;
        }

        $headers = '';

        if (!empty(
            $row['custom_headers_json']
        )) {
            $decoded = json_decode(
                $row['custom_headers_json'],
                true
            );

            if (is_array($decoded)) {
                $headers = implode(
                    "\n",
                    $decoded
                );
            }
        }

        layoutStart(
            $action === 'add'
                ? 'Add source'
                : 'Edit source'
        );

        echo '<div class="card">';
        echo '<h2>' .
             ($action === 'add'
                ? 'Add source'
                : 'Edit source') .
             '</h2>';

        echo '<form method="post" action="/?page=sources&action=' .
             e($action) . '">';

        echo '<input type="hidden" name="csrf" value="' .
             e(Csrf::token()) . '">';

        echo '<input type="hidden" name="id" value="' .
             e($row['id']) . '">';

        echo '<label>Name</label>';
        echo '<input name="name" required value="' .
             e($row['name']) . '">';

        echo '<label>Subscription URL</label>';
        echo '<input type="url" name="url" required value="' .
             e($row['url']) . '">';

        echo '<label><input style="width:auto" type="checkbox" name="enabled" ' .
             ($row['enabled'] ? 'checked' : '') .
             '> Enabled</label><br><br>';

        echo '<label><input style="width:auto" type="checkbox" name="use_global_interval" ' .
             ($row['use_global_interval'] ? 'checked' : '') .
             '> Use global fetch interval</label>';

        echo '<label>Custom fetch interval (seconds)</label>';
        echo '<input type="number" min="1" name="fetch_interval_seconds" value="' .
             e($row[
                 'fetch_interval_seconds'
             ] ?? 10) . '">';

        echo '<label><input style="width:auto" type="checkbox" name="use_global_ttl" ' .
             ($row['use_global_ttl'] ? 'checked' : '') .
             '> Use global TTL</label>';

        echo '<label>Custom config lifetime (minutes)</label>';
        echo '<input type="number" min="1" name="ttl_minutes" value="' .
             e((int)round(
                 ($row[
                     'config_ttl_seconds'
                 ] ?? 3600) / 60
             )) . '">';

        echo '<label>Request timeout (seconds)</label>';
        echo '<input type="number" min="1" name="request_timeout_seconds" value="' .
             e($row[
                 'request_timeout_seconds'
             ] ?? 7) . '">';

        echo '<label>User-Agent</label>';
        echo '<input name="user_agent" value="' .
             e($row['user_agent'] ?? '') . '">';

        echo '<label>Custom headers — one per line</label>';
        echo '<textarea name="custom_headers" rows="6">' .
             e($headers) . '</textarea>';

        echo '<label><input style="width:auto" type="checkbox" name="verify_tls" ' .
             ($row['verify_tls'] ? 'checked' : '') .
             '> Verify TLS certificate</label><br><br>';

        echo '<button type="submit">Save</button> ';
        echo '<a class="btn secondary" href="/?page=sources">Cancel</a>';
        echo '</form></div>';

        layoutEnd();
        exit;
    }

    layoutStart('Sources');

    echo '<div class="card">';
    echo '<div style="display:flex;justify-content:space-between;align-items:center">';
    echo '<h2>Sources</h2>';
    echo '<a class="btn" href="/?page=sources&action=add">Add source</a>';
    echo '</div>';

    $rows = $sources->all();

    if (!$rows) {
        echo '<p>No sources configured.</p>';
    } else {
        echo '<div style="overflow:auto"><table>';
        echo '<tr>';
        echo '<th>ID</th><th>Name</th><th>Status</th>';
        echo '<th>Interval</th><th>TTL</th>';
        echo '<th>Last fetch</th><th>Failures</th><th>Actions</th>';
        echo '</tr>';

        foreach ($rows as $r) {
            $interval = $r[
                'use_global_interval'
            ]
                ? 'Global'
                : e($r[
                    'fetch_interval_seconds'
                ]) . 's';

            $ttl = $r['use_global_ttl']
                ? 'Global'
                : e(
                    (int)round(
                        $r[
                            'config_ttl_seconds'
                        ] / 60
                    )
                ) . 'm';

            echo '<tr>';
            echo '<td>' . e($r['id']) . '</td>';
            echo '<td><strong>' . e($r['name']) . '</strong><br><small>' .
                 e($r['url']) . '</small></td>';
            echo '<td>' .
                 ($r['enabled']
                    ? '<span class="ok">Enabled</span>'
                    : '<span class="bad">Disabled</span>') .
                 '</td>';
            echo '<td>' . $interval . '</td>';
            echo '<td>' . $ttl . '</td>';
            echo '<td>' .
                 ($r['last_fetch_at']
                    ? e(date(
                        'Y-m-d H:i:s',
                        $r['last_fetch_at']
                    ))
                    : 'Never') .
                 '</td>';
            echo '<td>' .
                 e($r[
                     'consecutive_failures'
                 ]) .
                 '</td>';

            echo '<td><div class="actions">';
            echo '<a class="btn" href="/?page=sources&action=edit&id=' .
                 e($r['id']) .
                 '">Edit</a>';

            echo '<form method="post" action="/?page=sources&action=toggle">';
            echo '<input type="hidden" name="csrf" value="' .
                 e(Csrf::token()) . '">';
            echo '<input type="hidden" name="id" value="' .
                 e($r['id']) . '">';
            echo '<button class="secondary" type="submit">' .
                 ($r['enabled']
                    ? 'Disable'
                    : 'Enable') .
                 '</button></form>';

            echo '<form method="post" action="/?page=sources&action=delete" onsubmit="return confirm(\'Delete source?\')">';
            echo '<input type="hidden" name="csrf" value="' .
                 e(Csrf::token()) . '">';
            echo '<input type="hidden" name="id" value="' .
                 e($r['id']) . '">';
            echo '<button class="danger" type="submit">Delete</button>';
            echo '</form>';

            echo '</div></td>';
            echo '</tr>';
        }

        echo '</table></div>';
    }

    echo '</div>';

    layoutEnd();
    exit;
}

# Dashboard

layoutStart('Dashboard');

$pdo = $db->pdo();

$sourceCount = (int)$pdo
    ->query('SELECT COUNT(*) FROM sources')
    ->fetchColumn();

$enabledSources = (int)$pdo
    ->query(
        'SELECT COUNT(*) FROM sources WHERE enabled=1'
    )
    ->fetchColumn();

$configCount = (int)$pdo
    ->query('SELECT COUNT(*) FROM configs')
    ->fetchColumn();

$activeConfigs = (int)$pdo
    ->query(
        'SELECT COUNT(*) FROM configs WHERE active=1 AND expires_at > ' .
        time()
    )
    ->fetchColumn();

echo '<div class="grid">';
echo '<div class="stat"><small>Sources</small><h2>' .
     e($sourceCount) . '</h2></div>';
echo '<div class="stat"><small>Enabled Sources</small><h2>' .
     e($enabledSources) . '</h2></div>';
echo '<div class="stat"><small>Total Configs</small><h2>' .
     e($configCount) . '</h2></div>';
echo '<div class="stat"><small>Active Configs</small><h2>' .
     e($activeConfigs) . '</h2></div>';
echo '</div>';

echo '<div class="card">';
echo '<h2>Core status</h2>';
echo '<p>Database: <span class="ok">Online</span></p>';
echo '<p>Journal mode: <strong>' .
     e(
         $pdo->query(
             'PRAGMA journal_mode'
         )->fetchColumn()
     ) .
     '</strong></p>';
echo '<p>Foreign keys: <strong>' .
     e(
         $pdo->query(
             'PRAGMA foreign_keys'
         )->fetchColumn()
     ) .
     '</strong></p>';
echo '<p>Fetcher: not installed yet</p>';
echo '</div>';

layoutEnd();
