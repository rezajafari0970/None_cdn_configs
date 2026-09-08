#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT="/root/None_cdn_configs"
APP="/opt/nonecdn"
DATA="/var/lib/nonecdn"
DB="$DATA/database/nonecdn.sqlite"
STATE="$DATA/state"
LOG="/var/log/nonecdn"

PANEL_PORT="18088"
PANEL_USER="nonecdn"
PHP_MM="$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;')"
FPM_POOL="/etc/php/${PHP_MM}/fpm/pool.d/nonecdn-panel.conf"
FPM_SOCKET="/run/php/nonecdn-panel.sock"
NGINX_SITE="/etc/nginx/conf.d/nonecdn-panel.conf"

echo "============================================================"
echo " NoneCDN PANEL v0.1"
echo "============================================================"
echo "Started: $(date -Is)"
echo

if [ "$(id -u)" -ne 0 ]; then
    echo "[FAIL] Run as root"
    exit 1
fi

if [ ! -f "$DB" ]; then
    echo "[FAIL] Database missing: $DB"
    exit 1
fi

if ss -lnt | awk '{print $4}' | grep -Eq "(:|\])${PANEL_PORT}$"; then
    echo "[FAIL] Port $PANEL_PORT already in use."
    exit 1
fi

mkdir -p \
    "$PROJECT/panel" \
    "$PROJECT/src/Auth" \
    "$PROJECT/src/Panel" \
    "$PROJECT/tests/integration" \
    "$PROJECT/reports/runs" \
    "$APP/panel" \
    "$STATE/sessions"

chown nonecdn:nonecdn "$STATE/sessions"
chmod 750 "$STATE/sessions"

# ============================================================
# AUTH
# ============================================================

cat > "$PROJECT/src/Auth/Auth.php" <<'PHP'
<?php
declare(strict_types=1);

namespace NoneCDN\Auth;

final class Auth
{
    private const HASH_FILE =
        '/var/lib/nonecdn/state/admin-password.hash';

    public static function initialized(): bool
    {
        return is_file(self::HASH_FILE);
    }

    public static function setPassword(string $password): void
    {
        if (strlen($password) < 10) {
            throw new \InvalidArgumentException(
                'Password must contain at least 10 characters.'
            );
        }

        $hash = password_hash(
            $password,
            PASSWORD_DEFAULT
        );

        if (!$hash) {
            throw new \RuntimeException(
                'Password hashing failed.'
            );
        }

        if (file_put_contents(
            self::HASH_FILE,
            $hash,
            LOCK_EX
        ) === false) {
            throw new \RuntimeException(
                'Unable to write password hash.'
            );
        }

        chmod(self::HASH_FILE, 0640);
    }

    public static function verify(string $password): bool
    {
        if (!self::initialized()) {
            return false;
        }

        $hash = trim(
            (string)file_get_contents(
                self::HASH_FILE
            )
        );

        return password_verify(
            $password,
            $hash
        );
    }

    public static function login(): void
    {
        session_regenerate_id(true);

        $_SESSION['authenticated'] = true;
        $_SESSION['authenticated_at'] = time();
    }

    public static function logout(): void
    {
        $_SESSION = [];

        if (session_id() !== '') {
            session_destroy();
        }
    }

    public static function check(): bool
    {
        return !empty(
            $_SESSION['authenticated']
        );
    }
}
PHP

# ============================================================
# CSRF
# ============================================================

cat > "$PROJECT/src/Panel/Csrf.php" <<'PHP'
<?php
declare(strict_types=1);

namespace NoneCDN\Panel;

final class Csrf
{
    public static function token(): string
    {
        if (empty($_SESSION['csrf'])) {
            $_SESSION['csrf'] =
                bin2hex(random_bytes(32));
        }

        return $_SESSION['csrf'];
    }

    public static function validate(
        ?string $token
    ): bool {
        if (
            empty($_SESSION['csrf']) ||
            !$token
        ) {
            return false;
        }

        return hash_equals(
            $_SESSION['csrf'],
            $token
        );
    }
}
PHP

# ============================================================
# PANEL APP
# ============================================================

cat > "$PROJECT/panel/index.php" <<'PHP'
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
PHP

# ============================================================
# PASSWORD INITIALIZATION CLI
# ============================================================

cat > "$PROJECT/scripts/panel-init-password.php" <<'PHP'
<?php
declare(strict_types=1);

require '/opt/nonecdn/src/autoload.php';

use NoneCDN\Auth\Auth;

$password = $argv[1] ?? '';

if ($password === '') {
    fwrite(STDERR, "Password required\n");
    exit(1);
}

Auth::setPassword($password);

echo "[OK] Panel password initialized\n";
PHP

# ============================================================
# DEPLOY
# ============================================================

rm -rf "$APP/panel"

cp -a "$PROJECT/panel" "$APP/panel"

mkdir -p "$APP/src/Auth" "$APP/src/Panel"

cp "$PROJECT/src/Auth/Auth.php" \
   "$APP/src/Auth/Auth.php"

cp "$PROJECT/src/Panel/Csrf.php" \
   "$APP/src/Panel/Csrf.php"

cp "$PROJECT/scripts/panel-init-password.php" \
   "$APP/scripts/panel-init-password.php"

chown -R root:root \
    "$APP/panel" \
    "$APP/src/Auth" \
    "$APP/src/Panel" \
    "$APP/scripts/panel-init-password.php"

find "$APP/panel" "$APP/src/Auth" "$APP/src/Panel" \
    -type d -exec chmod 755 {} \;

find "$APP/panel" "$APP/src/Auth" "$APP/src/Panel" \
    -type f -exec chmod 644 {} \;

chmod 644 "$APP/scripts/panel-init-password.php"

# ============================================================
# CREATE PASSWORD
# ============================================================

if [ ! -f "$STATE/admin-password.hash" ]; then
    PANEL_PASSWORD="$(
        openssl rand -base64 24 |
        tr -d '\n=/+' |
        head -c 20
    )"

    runuser -u nonecdn -- \
        php "$APP/scripts/panel-init-password.php" \
        "$PANEL_PASSWORD"

    echo
    echo "============================================================"
    echo " PANEL PASSWORD"
    echo "============================================================"
    echo "$PANEL_PASSWORD"
    echo "============================================================"
    echo
else
    echo "[OK] Existing panel password preserved."
fi

chown nonecdn:nonecdn \
    "$STATE/admin-password.hash"

chmod 640 \
    "$STATE/admin-password.hash"

# ============================================================
# DEDICATED FPM POOL
# ============================================================

cat > "$FPM_POOL" <<EOF
[nonecdn-panel]

user = nonecdn
group = nonecdn

listen = $FPM_SOCKET
listen.owner = www-data
listen.group = www-data
listen.mode = 0660

pm = dynamic
pm.max_children = 8
pm.start_servers = 2
pm.min_spare_servers = 1
pm.max_spare_servers = 4
pm.max_requests = 1000

php_admin_value[session.save_path] = /var/lib/nonecdn/state/sessions
php_admin_value[upload_tmp_dir] = /var/lib/nonecdn/cache

php_admin_flag[log_errors] = on
php_admin_value[error_log] = /var/log/nonecdn/panel-php-error.log

php_admin_value[memory_limit] = 128M
php_admin_value[max_execution_time] = 30
php_admin_value[post_max_size] = 2M
php_admin_value[upload_max_filesize] = 2M

clear_env = yes
catch_workers_output = yes
EOF

php-fpm${PHP_MM} -t

systemctl reload \
    "php${PHP_MM}-fpm.service"

sleep 1

if [ ! -S "$FPM_SOCKET" ]; then
    echo "[FAIL] NoneCDN FPM socket not created."
    exit 1
fi

echo "[OK] Dedicated PHP-FPM pool"

# ============================================================
# NGINX ISOLATED SERVER
# ============================================================

cat > "$NGINX_SITE" <<EOF
server {
    listen $PANEL_PORT;
    listen [::]:$PANEL_PORT;

    server_name _;

    root /opt/nonecdn/panel;
    index index.php;

    access_log /var/log/nonecdn/panel-access.log;
    error_log  /var/log/nonecdn/panel-nginx-error.log;

    client_max_body_size 2m;

    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }

    location ~ \.php\$ {
        try_files \$uri =404;

        include fastcgi_params;

        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        fastcgi_param HTTP_PROXY "";

        fastcgi_pass unix:$FPM_SOCKET;
    }

    location ~ /\.(?!well-known) {
        deny all;
    }
}
EOF

nginx -t

systemctl reload nginx

sleep 1

if ! ss -lnt |
    awk '{print $4}' |
    grep -Eq "(:|\])${PANEL_PORT}$"
then
    echo "[FAIL] Panel port is not listening."
    exit 1
fi

echo "[OK] Nginx listener :$PANEL_PORT"

# ============================================================
# HTTP TEST
# ============================================================

HTTP_CODE="$(
    curl \
        -sS \
        -o /tmp/nonecdn-panel-test.html \
        -w '%{http_code}' \
        "http://127.0.0.1:${PANEL_PORT}/"
)"

if [ "$HTTP_CODE" != "200" ]; then
    echo "[FAIL] Panel HTTP test: $HTTP_CODE"
    cat /tmp/nonecdn-panel-test.html || true
    exit 1
fi

grep -q "NoneCDN Login" \
    /tmp/nonecdn-panel-test.html

echo "[OK] Login page HTTP test"

# ============================================================
# HARD FOREIGN KEY TEST
# ============================================================

runuser -u nonecdn -- php -r '
require "/opt/nonecdn/src/autoload.php";

$db = new \NoneCDN\Database\Database(
    "/var/lib/nonecdn/database/nonecdn.sqlite"
);

$pdo = $db->pdo();

if ((int)$pdo->query(
    "PRAGMA foreign_keys"
)->fetchColumn() !== 1) {
    throw new RuntimeException(
        "foreign_keys pragma disabled"
    );
}

try {
    $pdo->exec("
        INSERT INTO config_sources (
            config_id,
            source_id,
            first_seen_at,
            last_seen_at,
            expires_at,
            seen_count
        )
        VALUES (
            987654321,
            987654321,
            1,
            1,
            2,
            1
        )
    ");

    throw new RuntimeException(
        "FK enforcement test unexpectedly succeeded"
    );

} catch (\PDOException $e) {
    if (
        stripos(
            $e->getMessage(),
            "FOREIGN KEY"
        ) === false
    ) {
        throw $e;
    }
}

echo "[OK] Hard foreign key enforcement test\n";
'

# ============================================================
# STATUS REPORT
# ============================================================

cat >> "$PROJECT/reports/PROJECT-STATUS.md" <<EOF

## Panel Stage 2

Completed: $(date -Is)

- [x] Admin authentication
- [x] Session isolation
- [x] CSRF protection
- [x] Dashboard
- [x] Global Settings UI
- [x] Sources UI
- [x] Add/Edit/Delete source
- [x] Enable/Disable source
- [x] Per-source fetch interval
- [x] Per-source TTL
- [x] Request timeout
- [x] TLS verification
- [x] Custom headers
- [x] Dedicated PHP-FPM pool
- [x] Dedicated Nginx listener
- [x] HTTP integration test
- [x] Hard SQLite foreign-key enforcement test

Status:

PANEL v0.1 COMPLETE

Panel port:

$PANEL_PORT
EOF

REPORT="$PROJECT/reports/runs/panel-stage2-$(date +%Y%m%d-%H%M%S).txt"

{
    echo "NoneCDN Panel v0.1"
    echo "Date: $(date -Is)"
    echo
    echo "Port: $PANEL_PORT"
    echo
    echo "FPM socket:"
    ls -l "$FPM_SOCKET"
    echo
    echo "Nginx:"
    nginx -t 2>&1
    echo
    echo "HTTP:"
    curl -sSI "http://127.0.0.1:${PANEL_PORT}/" | head
    echo
    echo "Database:"
    ls -lh "$DB"
} > "$REPORT"

echo
echo "============================================================"
echo " PANEL v0.1 COMPLETE"
echo "============================================================"
echo
echo "URL:"
echo "http://SERVER-IP:${PANEL_PORT}/"
echo
echo "If this was the first installation,"
echo "save the password shown above."
echo
echo "Next:"
echo "Parser + CDN Detection Engine"
echo
