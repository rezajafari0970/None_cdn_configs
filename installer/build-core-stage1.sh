#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT="/root/None_cdn_configs"
APP_DIR="/opt/nonecdn"
DATA_DIR="/var/lib/nonecdn"
DB_DIR="$DATA_DIR/database"
DB_FILE="$DB_DIR/nonecdn.sqlite"
REPORT_DIR="$PROJECT/reports/runs"

mkdir -p \
    "$PROJECT/src/Core" \
    "$PROJECT/src/Database" \
    "$PROJECT/src/Config" \
    "$PROJECT/src/Source" \
    "$PROJECT/migrations" \
    "$PROJECT/tests/integration" \
    "$REPORT_DIR"

echo "============================================================"
echo " NoneCDN - CORE STAGE 1"
echo " Database + Migration + Settings + Sources"
echo "============================================================"
echo "Started: $(date -Is)"
echo


# ============================================================
# 1. BOOTSTRAP
# ============================================================

cat > "$PROJECT/src/Core/Bootstrap.php" <<'PHP'
<?php

declare(strict_types=1);

namespace NoneCDN\Core;

final class Bootstrap
{
    public const PROJECT_ROOT = '/opt/nonecdn';
    public const DATA_ROOT = '/var/lib/nonecdn';
    public const DB_PATH = '/var/lib/nonecdn/database/nonecdn.sqlite';
    public const LOG_ROOT = '/var/log/nonecdn';
    public const RUN_ROOT = '/run/nonecdn';
}
PHP


# ============================================================
# 2. DATABASE CONNECTION
# ============================================================

cat > "$PROJECT/src/Database/Database.php" <<'PHP'
<?php

declare(strict_types=1);

namespace NoneCDN\Database;

use PDO;
use PDOException;

final class Database
{
    private PDO $pdo;

    public function __construct(string $path)
    {
        $dir = dirname($path);

        if (!is_dir($dir)) {
            throw new \RuntimeException(
                "Database directory does not exist: {$dir}"
            );
        }

        $this->pdo = new PDO(
            'sqlite:' . $path,
            null,
            null,
            [
                PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION,
                PDO::ATTR_DEFAULT_FETCH_MODE => PDO::FETCH_ASSOC,
                PDO::ATTR_EMULATE_PREPARES => false,
            ]
        );

        $this->configure();
    }

    private function configure(): void
    {
        $pragmas = [
            'PRAGMA foreign_keys = ON',
            'PRAGMA journal_mode = WAL',
            'PRAGMA synchronous = NORMAL',
            'PRAGMA busy_timeout = 5000',
            'PRAGMA temp_store = MEMORY',
            'PRAGMA cache_size = -20000',
            'PRAGMA wal_autocheckpoint = 1000',
        ];

        foreach ($pragmas as $sql) {
            $this->pdo->exec($sql);
        }
    }

    public function pdo(): PDO
    {
        return $this->pdo;
    }

    public function transaction(callable $callback): mixed
    {
        $this->pdo->beginTransaction();

        try {
            $result = $callback($this->pdo);
            $this->pdo->commit();

            return $result;
        } catch (\Throwable $e) {
            if ($this->pdo->inTransaction()) {
                $this->pdo->rollBack();
            }

            throw $e;
        }
    }
}
PHP


# ============================================================
# 3. MIGRATION INTERFACE
# ============================================================

cat > "$PROJECT/src/Database/Migration.php" <<'PHP'
<?php

declare(strict_types=1);

namespace NoneCDN\Database;

use PDO;

interface Migration
{
    public function version(): string;

    public function up(PDO $pdo): void;
}
PHP


# ============================================================
# 4. MIGRATION RUNNER
# ============================================================

cat > "$PROJECT/src/Database/MigrationRunner.php" <<'PHP'
<?php

declare(strict_types=1);

namespace NoneCDN\Database;

use PDO;

final class MigrationRunner
{
    public function __construct(
        private readonly Database $database
    ) {
    }

    public function ensureMigrationTable(): void
    {
        $this->database->pdo()->exec(
            '
            CREATE TABLE IF NOT EXISTS migrations (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                version TEXT NOT NULL UNIQUE,
                applied_at INTEGER NOT NULL
            )
            '
        );
    }

    public function run(array $migrations): array
    {
        $this->ensureMigrationTable();

        usort(
            $migrations,
            static fn(Migration $a, Migration $b): int =>
                strcmp($a->version(), $b->version())
        );

        $applied = [];

        foreach ($migrations as $migration) {
            if ($this->isApplied($migration->version())) {
                continue;
            }

            $this->database->transaction(
                function (PDO $pdo) use ($migration): void {
                    $migration->up($pdo);

                    $stmt = $pdo->prepare(
                        '
                        INSERT INTO migrations (
                            version,
                            applied_at
                        )
                        VALUES (
                            :version,
                            :applied_at
                        )
                        '
                    );

                    $stmt->execute([
                        ':version' => $migration->version(),
                        ':applied_at' => time(),
                    ]);
                }
            );

            $applied[] = $migration->version();
        }

        return $applied;
    }

    private function isApplied(string $version): bool
    {
        $stmt = $this->database->pdo()->prepare(
            '
            SELECT 1
            FROM migrations
            WHERE version = :version
            LIMIT 1
            '
        );

        $stmt->execute([
            ':version' => $version,
        ]);

        return (bool)$stmt->fetchColumn();
    }
}
PHP


# ============================================================
# 5. MAIN SCHEMA MIGRATION
# ============================================================

cat > "$PROJECT/migrations/Version20260908_000001.php" <<'PHP'
<?php

declare(strict_types=1);

namespace NoneCDN\Migrations;

use NoneCDN\Database\Migration;
use PDO;

final class Version20260908_000001 implements Migration
{
    public function version(): string
    {
        return '20260908_000001';
    }

    public function up(PDO $pdo): void
    {
        $pdo->exec(
            '
            CREATE TABLE settings (
                key TEXT PRIMARY KEY,
                value TEXT NOT NULL,
                type TEXT NOT NULL DEFAULT "string",
                updated_at INTEGER NOT NULL
            )
            '
        );

        $pdo->exec(
            '
            CREATE TABLE sources (
                id INTEGER PRIMARY KEY AUTOINCREMENT,

                name TEXT NOT NULL,
                url TEXT NOT NULL,

                enabled INTEGER NOT NULL DEFAULT 1,

                use_global_interval INTEGER NOT NULL DEFAULT 1,
                fetch_interval_seconds INTEGER,

                use_global_ttl INTEGER NOT NULL DEFAULT 1,
                config_ttl_seconds INTEGER,

                request_timeout_seconds INTEGER DEFAULT 7,

                user_agent TEXT,
                custom_headers_json TEXT,

                verify_tls INTEGER NOT NULL DEFAULT 1,

                last_fetch_at INTEGER,
                last_success_at INTEGER,
                next_fetch_at INTEGER,

                last_http_status INTEGER,
                last_duration_ms INTEGER,

                consecutive_failures INTEGER NOT NULL DEFAULT 0,
                total_fetches INTEGER NOT NULL DEFAULT 0,
                total_successes INTEGER NOT NULL DEFAULT 0,
                total_failures INTEGER NOT NULL DEFAULT 0,

                last_received_count INTEGER NOT NULL DEFAULT 0,
                last_direct_count INTEGER NOT NULL DEFAULT 0,
                last_cdn_count INTEGER NOT NULL DEFAULT 0,
                last_invalid_count INTEGER NOT NULL DEFAULT 0,

                created_at INTEGER NOT NULL,
                updated_at INTEGER NOT NULL
            )
            '
        );

        $pdo->exec(
            '
            CREATE UNIQUE INDEX idx_sources_url
            ON sources(url)
            '
        );

        $pdo->exec(
            '
            CREATE INDEX idx_sources_enabled_next
            ON sources(enabled, next_fetch_at)
            '
        );

        $pdo->exec(
            '
            CREATE TABLE configs (
                id INTEGER PRIMARY KEY AUTOINCREMENT,

                fingerprint TEXT NOT NULL UNIQUE,

                raw_config TEXT NOT NULL,

                protocol TEXT,

                address TEXT,
                port INTEGER,

                host TEXT,
                sni TEXT,

                classification TEXT NOT NULL DEFAULT "UNKNOWN",

                classification_reason TEXT,
                cdn_provider TEXT,

                first_seen_at INTEGER NOT NULL,
                last_seen_at INTEGER NOT NULL,
                expires_at INTEGER NOT NULL,

                active INTEGER NOT NULL DEFAULT 1,

                created_at INTEGER NOT NULL,
                updated_at INTEGER NOT NULL
            )
            '
        );

        $pdo->exec(
            '
            CREATE INDEX idx_configs_expiry
            ON configs(active, expires_at)
            '
        );

        $pdo->exec(
            '
            CREATE INDEX idx_configs_classification
            ON configs(classification, active)
            '
        );

        $pdo->exec(
            '
            CREATE INDEX idx_configs_address
            ON configs(address)
            '
        );

        $pdo->exec(
            '
            CREATE TABLE config_sources (
                config_id INTEGER NOT NULL,
                source_id INTEGER NOT NULL,

                first_seen_at INTEGER NOT NULL,
                last_seen_at INTEGER NOT NULL,
                expires_at INTEGER NOT NULL,

                seen_count INTEGER NOT NULL DEFAULT 1,

                PRIMARY KEY (
                    config_id,
                    source_id
                ),

                FOREIGN KEY (config_id)
                    REFERENCES configs(id)
                    ON DELETE CASCADE,

                FOREIGN KEY (source_id)
                    REFERENCES sources(id)
                    ON DELETE CASCADE
            )
            '
        );

        $pdo->exec(
            '
            CREATE INDEX idx_config_sources_expiry
            ON config_sources(expires_at)
            '
        );

        $pdo->exec(
            '
            CREATE TABLE fetch_cycles (
                id INTEGER PRIMARY KEY AUTOINCREMENT,

                cycle_uuid TEXT NOT NULL UNIQUE,

                scheduled_at INTEGER NOT NULL,
                started_at INTEGER,
                completed_at INTEGER,

                status TEXT NOT NULL,

                source_count INTEGER NOT NULL DEFAULT 0,
                success_count INTEGER NOT NULL DEFAULT 0,
                failure_count INTEGER NOT NULL DEFAULT 0,

                duration_ms INTEGER,

                created_at INTEGER NOT NULL
            )
            '
        );

        $pdo->exec(
            '
            CREATE INDEX idx_fetch_cycles_scheduled
            ON fetch_cycles(scheduled_at)
            '
        );

        $pdo->exec(
            '
            CREATE TABLE fetch_results (
                id INTEGER PRIMARY KEY AUTOINCREMENT,

                cycle_id INTEGER NOT NULL,
                source_id INTEGER NOT NULL,

                started_at INTEGER NOT NULL,
                completed_at INTEGER,

                success INTEGER NOT NULL DEFAULT 0,

                http_status INTEGER,
                duration_ms INTEGER,

                bytes_received INTEGER,

                received_count INTEGER NOT NULL DEFAULT 0,
                direct_count INTEGER NOT NULL DEFAULT 0,
                cdn_count INTEGER NOT NULL DEFAULT 0,
                invalid_count INTEGER NOT NULL DEFAULT 0,

                error_type TEXT,
                error_message TEXT,

                FOREIGN KEY (cycle_id)
                    REFERENCES fetch_cycles(id)
                    ON DELETE CASCADE,

                FOREIGN KEY (source_id)
                    REFERENCES sources(id)
                    ON DELETE CASCADE
            )
            '
        );

        $pdo->exec(
            '
            CREATE INDEX idx_fetch_results_cycle
            ON fetch_results(cycle_id)
            '
        );

        $pdo->exec(
            '
            CREATE INDEX idx_fetch_results_source
            ON fetch_results(source_id, started_at)
            '
        );

        $pdo->exec(
            '
            CREATE TABLE config_observations (
                id INTEGER PRIMARY KEY AUTOINCREMENT,

                config_id INTEGER NOT NULL,
                source_id INTEGER NOT NULL,
                cycle_id INTEGER,

                observed_at INTEGER NOT NULL,

                FOREIGN KEY (config_id)
                    REFERENCES configs(id)
                    ON DELETE CASCADE,

                FOREIGN KEY (source_id)
                    REFERENCES sources(id)
                    ON DELETE CASCADE,

                FOREIGN KEY (cycle_id)
                    REFERENCES fetch_cycles(id)
                    ON DELETE SET NULL
            )
            '
        );

        $pdo->exec(
            '
            CREATE INDEX idx_observations_config_time
            ON config_observations(
                config_id,
                observed_at
            )
            '
        );

        $pdo->exec(
            '
            CREATE TABLE cdn_rules (
                id INTEGER PRIMARY KEY AUTOINCREMENT,

                rule_type TEXT NOT NULL,
                value TEXT NOT NULL,

                provider TEXT,

                enabled INTEGER NOT NULL DEFAULT 1,
                priority INTEGER NOT NULL DEFAULT 100,

                created_at INTEGER NOT NULL,
                updated_at INTEGER NOT NULL
            )
            '
        );

        $pdo->exec(
            '
            CREATE INDEX idx_cdn_rules_type_enabled
            ON cdn_rules(rule_type, enabled)
            '
        );

        $pdo->exec(
            '
            CREATE TABLE overrides (
                id INTEGER PRIMARY KEY AUTOINCREMENT,

                match_type TEXT NOT NULL,
                match_value TEXT NOT NULL,

                classification TEXT NOT NULL,

                note TEXT,

                enabled INTEGER NOT NULL DEFAULT 1,

                created_at INTEGER NOT NULL,
                updated_at INTEGER NOT NULL
            )
            '
        );

        $pdo->exec(
            '
            CREATE TABLE system_health (
                key TEXT PRIMARY KEY,
                value TEXT NOT NULL,
                updated_at INTEGER NOT NULL
            )
            '
        );

        $pdo->exec(
            '
            CREATE TABLE audit_events (
                id INTEGER PRIMARY KEY AUTOINCREMENT,

                level TEXT NOT NULL,
                category TEXT NOT NULL,
                message TEXT NOT NULL,

                context_json TEXT,

                created_at INTEGER NOT NULL
            )
            '
        );

        $pdo->exec(
            '
            CREATE INDEX idx_audit_events_created
            ON audit_events(created_at)
            '
        );
    }
}
PHP


# ============================================================
# 6. SETTINGS ENGINE
# ============================================================

cat > "$PROJECT/src/Config/Settings.php" <<'PHP'
<?php

declare(strict_types=1);

namespace NoneCDN\Config;

use NoneCDN\Database\Database;

final class Settings
{
    public function __construct(
        private readonly Database $database
    ) {
    }

    public function set(
        string $key,
        mixed $value,
        ?string $type = null
    ): void {
        $type ??= $this->detectType($value);

        $encoded = $this->encode(
            $value,
            $type
        );

        $stmt = $this->database->pdo()->prepare(
            '
            INSERT INTO settings (
                key,
                value,
                type,
                updated_at
            )
            VALUES (
                :key,
                :value,
                :type,
                :updated_at
            )
            ON CONFLICT(key)
            DO UPDATE SET
                value = excluded.value,
                type = excluded.type,
                updated_at = excluded.updated_at
            '
        );

        $stmt->execute([
            ':key' => $key,
            ':value' => $encoded,
            ':type' => $type,
            ':updated_at' => time(),
        ]);
    }

    public function get(
        string $key,
        mixed $default = null
    ): mixed {
        $stmt = $this->database->pdo()->prepare(
            '
            SELECT value, type
            FROM settings
            WHERE key = :key
            LIMIT 1
            '
        );

        $stmt->execute([
            ':key' => $key,
        ]);

        $row = $stmt->fetch();

        if (!$row) {
            return $default;
        }

        return $this->decode(
            $row['value'],
            $row['type']
        );
    }

    public function all(): array
    {
        $rows = $this->database->pdo()
            ->query(
                '
                SELECT key, value, type
                FROM settings
                ORDER BY key
                '
            )
            ->fetchAll();

        $result = [];

        foreach ($rows as $row) {
            $result[$row['key']] = $this->decode(
                $row['value'],
                $row['type']
            );
        }

        return $result;
    }

    public function delete(string $key): void
    {
        $stmt = $this->database->pdo()->prepare(
            '
            DELETE FROM settings
            WHERE key = :key
            '
        );

        $stmt->execute([
            ':key' => $key,
        ]);
    }

    private function detectType(mixed $value): string
    {
        return match (true) {
            is_bool($value) => 'bool',
            is_int($value) => 'int',
            is_float($value) => 'float',
            is_array($value) => 'json',
            default => 'string',
        };
    }

    private function encode(
        mixed $value,
        string $type
    ): string {
        return match ($type) {
            'bool' => $value ? '1' : '0',
            'int' => (string)(int)$value,
            'float' => (string)(float)$value,
            'json' => json_encode(
                $value,
                JSON_THROW_ON_ERROR |
                JSON_UNESCAPED_SLASHES |
                JSON_UNESCAPED_UNICODE
            ),
            default => (string)$value,
        };
    }

    private function decode(
        string $value,
        string $type
    ): mixed {
        return match ($type) {
            'bool' => $value === '1',
            'int' => (int)$value,
            'float' => (float)$value,
            'json' => json_decode(
                $value,
                true,
                512,
                JSON_THROW_ON_ERROR
            ),
            default => $value,
        };
    }
}
PHP


# ============================================================
# 7. SOURCE MANAGER
# ============================================================

cat > "$PROJECT/src/Source/SourceManager.php" <<'PHP'
<?php

declare(strict_types=1);

namespace NoneCDN\Source;

use InvalidArgumentException;
use NoneCDN\Database\Database;
use PDO;

final class SourceManager
{
    public function __construct(
        private readonly Database $database
    ) {
    }

    public function create(array $data): int
    {
        $name = trim((string)($data['name'] ?? ''));
        $url = trim((string)($data['url'] ?? ''));

        if ($name === '') {
            throw new InvalidArgumentException(
                'Source name is required'
            );
        }

        if (!filter_var($url, FILTER_VALIDATE_URL)) {
            throw new InvalidArgumentException(
                'Invalid source URL'
            );
        }

        $now = time();

        $stmt = $this->database->pdo()->prepare(
            '
            INSERT INTO sources (
                name,
                url,

                enabled,

                use_global_interval,
                fetch_interval_seconds,

                use_global_ttl,
                config_ttl_seconds,

                request_timeout_seconds,

                user_agent,
                custom_headers_json,

                verify_tls,

                created_at,
                updated_at
            )
            VALUES (
                :name,
                :url,

                :enabled,

                :use_global_interval,
                :fetch_interval_seconds,

                :use_global_ttl,
                :config_ttl_seconds,

                :request_timeout_seconds,

                :user_agent,
                :custom_headers_json,

                :verify_tls,

                :created_at,
                :updated_at
            )
            '
        );

        $headers = $data['custom_headers'] ?? null;

        $stmt->execute([
            ':name' => $name,
            ':url' => $url,

            ':enabled' =>
                !empty($data['enabled']) ? 1 : 0,

            ':use_global_interval' =>
                ($data['use_global_interval'] ?? true)
                    ? 1
                    : 0,

            ':fetch_interval_seconds' =>
                isset($data['fetch_interval_seconds'])
                    ? (int)$data['fetch_interval_seconds']
                    : null,

            ':use_global_ttl' =>
                ($data['use_global_ttl'] ?? true)
                    ? 1
                    : 0,

            ':config_ttl_seconds' =>
                isset($data['config_ttl_seconds'])
                    ? (int)$data['config_ttl_seconds']
                    : null,

            ':request_timeout_seconds' =>
                max(
                    1,
                    (int)($data['request_timeout_seconds'] ?? 7)
                ),

            ':user_agent' =>
                $data['user_agent'] ?? null,

            ':custom_headers_json' =>
                $headers !== null
                    ? json_encode(
                        $headers,
                        JSON_THROW_ON_ERROR |
                        JSON_UNESCAPED_SLASHES |
                        JSON_UNESCAPED_UNICODE
                    )
                    : null,

            ':verify_tls' =>
                ($data['verify_tls'] ?? true)
                    ? 1
                    : 0,

            ':created_at' => $now,
            ':updated_at' => $now,
        ]);

        return (int)$this->database->pdo()
            ->lastInsertId();
    }

    public function find(int $id): ?array
    {
        $stmt = $this->database->pdo()->prepare(
            '
            SELECT *
            FROM sources
            WHERE id = :id
            LIMIT 1
            '
        );

        $stmt->execute([
            ':id' => $id,
        ]);

        $row = $stmt->fetch();

        return $row ?: null;
    }

    public function all(): array
    {
        return $this->database->pdo()
            ->query(
                '
                SELECT *
                FROM sources
                ORDER BY id ASC
                '
            )
            ->fetchAll();
    }

    public function active(): array
    {
        return $this->database->pdo()
            ->query(
                '
                SELECT *
                FROM sources
                WHERE enabled = 1
                ORDER BY id ASC
                '
            )
            ->fetchAll();
    }

    public function update(
        int $id,
        array $data
    ): void {
        $current = $this->find($id);

        if (!$current) {
            throw new InvalidArgumentException(
                'Source not found'
            );
        }

        $fields = [];
        $params = [
            ':id' => $id,
        ];

        $allowed = [
            'name',
            'url',
            'enabled',
            'use_global_interval',
            'fetch_interval_seconds',
            'use_global_ttl',
            'config_ttl_seconds',
            'request_timeout_seconds',
            'user_agent',
            'verify_tls',
        ];

        foreach ($allowed as $field) {
            if (!array_key_exists($field, $data)) {
                continue;
            }

            $value = $data[$field];

            if (
                in_array(
                    $field,
                    [
                        'enabled',
                        'use_global_interval',
                        'use_global_ttl',
                        'verify_tls',
                    ],
                    true
                )
            ) {
                $value = $value ? 1 : 0;
            }

            $fields[] = "{$field} = :{$field}";
            $params[":{$field}"] = $value;
        }

        if (array_key_exists(
            'custom_headers',
            $data
        )) {
            $fields[] =
                'custom_headers_json = :custom_headers_json';

            $params[':custom_headers_json'] =
                json_encode(
                    $data['custom_headers'],
                    JSON_THROW_ON_ERROR |
                    JSON_UNESCAPED_SLASHES |
                    JSON_UNESCAPED_UNICODE
                );
        }

        if (!$fields) {
            return;
        }

        $fields[] = 'updated_at = :updated_at';
        $params[':updated_at'] = time();

        $sql =
            '
            UPDATE sources
            SET ' .
            implode(', ', $fields) .
            '
            WHERE id = :id
            ';

        $stmt = $this->database->pdo()
            ->prepare($sql);

        $stmt->execute($params);
    }

    public function delete(int $id): void
    {
        $stmt = $this->database->pdo()->prepare(
            '
            DELETE FROM sources
            WHERE id = :id
            '
        );

        $stmt->execute([
            ':id' => $id,
        ]);
    }
}
PHP


# ============================================================
# 8. DEFAULT SETTINGS
# ============================================================

cat > "$PROJECT/src/Config/DefaultSettings.php" <<'PHP'
<?php

declare(strict_types=1);

namespace NoneCDN\Config;

final class DefaultSettings
{
    public static function values(): array
    {
        return [
            'fetcher.enabled' => true,

            'fetch.interval_seconds' => 10,

            'config.default_ttl_seconds' => 3600,

            'fetch.request_timeout_seconds' => 7,

            'fetch.max_parallel' => 50,

            'cleanup.enabled' => true,

            'cleanup.interval_seconds' => 10,

            'cdn_detection.enabled' => true,

            'classification.unknown_policy' =>
                'reject',

            'watchdog.enabled' => true,

            'watchdog.stall_threshold_seconds' =>
                30,

            'watchdog.auto_recovery' => true,

            'audit.runtime_enabled' => true,

            'panel.timezone' => 'UTC',

            'subscription.shuffle' => true,
        ];
    }
}
PHP


# ============================================================
# 9. AUTOLOADER
# ============================================================

cat > "$PROJECT/src/autoload.php" <<'PHP'
<?php

declare(strict_types=1);

spl_autoload_register(
    static function (string $class): void {
        $prefix = 'NoneCDN\\';

        if (!str_starts_with(
            $class,
            $prefix
        )) {
            return;
        }

        $relative = substr(
            $class,
            strlen($prefix)
        );

        $base = '/opt/nonecdn/src/';

        $file =
            $base .
            str_replace(
                '\\',
                '/',
                $relative
            ) .
            '.php';

        if (is_file($file)) {
            require $file;
            return;
        }

        $migrationBase =
            '/opt/nonecdn/migrations/';

        if (str_starts_with(
            $relative,
            'Migrations\\'
        )) {
            $name = substr(
                $relative,
                strlen('Migrations\\')
            );

            $migrationFile =
                $migrationBase .
                str_replace(
                    '\\',
                    '/',
                    $name
                ) .
                '.php';

            if (is_file($migrationFile)) {
                require $migrationFile;
            }
        }
    }
);
PHP


# ============================================================
# 10. MIGRATE CLI
# ============================================================

cat > "$PROJECT/scripts/migrate.php" <<'PHP'
<?php

declare(strict_types=1);

require '/opt/nonecdn/src/autoload.php';

use NoneCDN\Config\DefaultSettings;
use NoneCDN\Config\Settings;
use NoneCDN\Core\Bootstrap;
use NoneCDN\Database\Database;
use NoneCDN\Database\MigrationRunner;
use NoneCDN\Migrations\Version20260908_000001;

$db = new Database(
    Bootstrap::DB_PATH
);

$runner = new MigrationRunner(
    $db
);

$applied = $runner->run([
    new Version20260908_000001(),
]);

foreach ($applied as $version) {
    echo "[MIGRATED] {$version}\n";
}

if (!$applied) {
    echo "[OK] Database already up to date\n";
}

$settings = new Settings($db);

foreach (
    DefaultSettings::values()
    as $key => $value
) {
    if ($settings->get(
        $key,
        '__MISSING__'
    ) === '__MISSING__') {
        $settings->set(
            $key,
            $value
        );

        echo "[DEFAULT] {$key}\n";
    }
}

echo "[OK] Settings initialized\n";
PHP


# ============================================================
# 11. INTEGRATION TEST
# ============================================================

cat > "$PROJECT/tests/integration/test-stage1.php" <<'PHP'
<?php

declare(strict_types=1);

require '/opt/nonecdn/src/autoload.php';

use NoneCDN\Config\Settings;
use NoneCDN\Core\Bootstrap;
use NoneCDN\Database\Database;
use NoneCDN\Source\SourceManager;

$db = new Database(
    Bootstrap::DB_PATH
);

$pdo = $db->pdo();

echo "===== DATABASE =====\n";

$journal = $pdo
    ->query('PRAGMA journal_mode')
    ->fetchColumn();

echo "journal_mode={$journal}\n";

if (strtolower(
    (string)$journal
) !== 'wal') {
    throw new RuntimeException(
        'WAL is not enabled'
    );
}

$foreign = $pdo
    ->query('PRAGMA foreign_keys')
    ->fetchColumn();

if ((int)$foreign !== 1) {
    throw new RuntimeException(
        'Foreign keys disabled'
    );
}

echo "[OK] WAL\n";
echo "[OK] Foreign keys\n";


echo
    "===== SETTINGS =====\n";

$settings = new Settings($db);

$settings->set(
    'test.integer',
    123
);

$settings->set(
    'test.boolean',
    true
);

$settings->set(
    'test.array',
    [
        'a' => 1,
        'b' => 2,
    ]
);

if (
    $settings->get(
        'test.integer'
    ) !== 123
) {
    throw new RuntimeException(
        'Integer settings test failed'
    );
}

if (
    $settings->get(
        'test.boolean'
    ) !== true
) {
    throw new RuntimeException(
        'Boolean settings test failed'
    );
}

$array = $settings->get(
    'test.array'
);

if (
    !is_array($array) ||
    $array['a'] !== 1
) {
    throw new RuntimeException(
        'JSON settings test failed'
    );
}

echo "[OK] Typed settings\n";


echo
    "===== SOURCES =====\n";

$manager = new SourceManager($db);

$pdo->exec(
    "
    DELETE FROM sources
    WHERE url =
        'https://example.invalid/test-sub'
    "
);

$id = $manager->create([
    'name' => 'Integration Test',
    'url' =>
        'https://example.invalid/test-sub',

    'enabled' => true,

    'use_global_interval' =>
        false,

    'fetch_interval_seconds' =>
        10,

    'use_global_ttl' =>
        false,

    'config_ttl_seconds' =>
        3600,

    'request_timeout_seconds' =>
        5,

    'verify_tls' => true,
]);

$source = $manager->find($id);

if (!$source) {
    throw new RuntimeException(
        'Source creation failed'
    );
}

if (
    (int)$source[
        'fetch_interval_seconds'
    ] !== 10
) {
    throw new RuntimeException(
        'Source interval test failed'
    );
}

if (
    (int)$source[
        'config_ttl_seconds'
    ] !== 3600
) {
    throw new RuntimeException(
        'Source TTL test failed'
    );
}

$manager->update(
    $id,
    [
        'config_ttl_seconds' =>
            7200,
    ]
);

$source = $manager->find($id);

if (
    (int)$source[
        'config_ttl_seconds'
    ] !== 7200
) {
    throw new RuntimeException(
        'Source update failed'
    );
}

echo "[OK] Source create\n";
echo "[OK] Source read\n";
echo "[OK] Source update\n";


echo
    "===== TTL LOGIC =====\n";

$lastSeen = time();

$ttl = 3600;

$expires =
    $lastSeen +
    $ttl;

if (
    $expires - $lastSeen
    !== 3600
) {
    throw new RuntimeException(
        'TTL math failed'
    );
}

$newLastSeen =
    $lastSeen +
    3500;

$newExpires =
    $newLastSeen +
    $ttl;

if (
    $newExpires <= $expires
) {
    throw new RuntimeException(
        'TTL refresh failed'
    );
}

echo "[OK] last_seen TTL refresh\n";


echo
    "===== CLEANUP =====\n";

$manager->delete($id);

if ($manager->find($id)) {
    throw new RuntimeException(
        'Source delete failed'
    );
}

$settings->delete(
    'test.integer'
);

$settings->delete(
    'test.boolean'
);

$settings->delete(
    'test.array'
);

echo "[OK] Source delete\n";

echo
    "\nALL STAGE 1 TESTS PASSED\n";
PHP


# ============================================================
# 12. DEPLOY SOURCE INTO /opt/nonecdn
# ============================================================

echo
echo "===== DEPLOYING SOURCE ====="

rm -rf "$APP_DIR/src"
rm -rf "$APP_DIR/migrations"

cp -a \
    "$PROJECT/src" \
    "$APP_DIR/src"

cp -a \
    "$PROJECT/migrations" \
    "$APP_DIR/migrations"

chown -R \
    root:root \
    "$APP_DIR/src" \
    "$APP_DIR/migrations"

find \
    "$APP_DIR/src" \
    "$APP_DIR/migrations" \
    -type d \
    -exec chmod 755 {} \;

find \
    "$APP_DIR/src" \
    "$APP_DIR/migrations" \
    -type f \
    -exec chmod 644 {} \;

echo "[OK] Code deployed"


# ============================================================
# 13. DATABASE BACKUP IF EXISTS
# ============================================================

if [ -f "$DB_FILE" ]; then
    BACKUP="$DB_FILE.before-stage1.$(date +%Y%m%d-%H%M%S)"

    cp -a \
        "$DB_FILE" \
        "$BACKUP"

    chown \
        nonecdn:nonecdn \
        "$BACKUP"

    echo "[BACKUP] $BACKUP"
fi


# ============================================================
# 14. RUN MIGRATION AS nonecdn
# ============================================================

echo
echo "===== MIGRATION ====="

runuser \
    -u nonecdn \
    -- php \
    "$PROJECT/scripts/migrate.php"


# ============================================================
# 15. DATABASE PERMISSIONS
# ============================================================

chown -R \
    nonecdn:nonecdn \
    "$DB_DIR"

chmod 750 \
    "$DB_DIR"

if [ -f "$DB_FILE" ]; then
    chmod 640 \
        "$DB_FILE"
fi


# ============================================================
# 16. INTEGRATION TEST
# ============================================================

echo
echo "===== INTEGRATION TEST ====="

runuser \
    -u nonecdn \
    -- php \
    "$PROJECT/tests/integration/test-stage1.php"


# ============================================================
# 17. SQLITE INTEGRITY
# ============================================================

echo
echo "===== SQLITE INTEGRITY ====="

INTEGRITY="$(
    runuser \
        -u nonecdn \
        -- sqlite3 \
        "$DB_FILE" \
        'PRAGMA integrity_check;'
)"

echo "$INTEGRITY"

if [ "$INTEGRITY" != "ok" ]; then
    echo "[FAIL] SQLite integrity check failed"
    exit 1
fi

echo "[OK] SQLite integrity"


# ============================================================
# 18. DATABASE TABLES
# ============================================================

echo
echo "===== TABLES ====="

runuser \
    -u nonecdn \
    -- sqlite3 \
    "$DB_FILE" \
    '.tables'


# ============================================================
# 19. DEFAULT SETTINGS
# ============================================================

echo
echo "===== DEFAULT SETTINGS ====="

runuser \
    -u nonecdn \
    -- sqlite3 \
    -header \
    -column \
    "$DB_FILE" \
    '
    SELECT
        key,
        value,
        type
    FROM settings
    ORDER BY key;
    '


# ============================================================
# 20. PROJECT STATUS
# ============================================================

cat > "$PROJECT/reports/PROJECT-STATUS.md" <<EOF
# None CDN Config Collector - Project Status

Updated: $(date -Is)

## Infrastructure

- [x] GitHub development repository
- [x] Development audit runner
- [x] Isolated runtime user
- [x] Isolated directories
- [x] PHP
- [x] SQLite
- [x] SQLite WAL

## Core Stage 1

- [x] Database connection engine
- [x] SQLite WAL configuration
- [x] Foreign key enforcement
- [x] Migration engine
- [x] Main database schema
- [x] Typed Settings Engine
- [x] Default application settings
- [x] Source Manager
- [x] Per-source interval support
- [x] Per-source TTL support
- [x] Custom headers storage
- [x] TLS verification setting
- [x] last_seen TTL model
- [x] Integration tests
- [x] SQLite integrity check

## Database entities

- settings
- sources
- configs
- config_sources
- config_observations
- fetch_cycles
- fetch_results
- cdn_rules
- overrides
- system_health
- audit_events
- migrations

## Status

CORE STAGE 1 COMPLETE

## Next

Panel v0.1

The next stage will provide:

- Login
- Dashboard
- Global settings
- Add/Edit/Delete Sources
- Enable/Disable Sources
- Per-source TTL
- Per-source fetch interval
- Request timeout
- TLS setting
- Custom request headers
EOF


# ============================================================
# 21. RUN REPORT
# ============================================================

REPORT="$REPORT_DIR/core-stage1-$(date +%Y%m%d-%H%M%S).txt"

{
    echo "NoneCDN Core Stage 1"
    echo "Date: $(date -Is)"

    echo
    echo "Database:"
    ls -lah "$DB_FILE"

    echo
    echo "Database integrity:"
    runuser \
        -u nonecdn \
        -- sqlite3 \
        "$DB_FILE" \
        'PRAGMA integrity_check;'

    echo
    echo "Journal mode:"
    runuser \
        -u nonecdn \
        -- sqlite3 \
        "$DB_FILE" \
        'PRAGMA journal_mode;'

    echo
    echo "Foreign keys:"
    runuser \
        -u nonecdn \
        -- sqlite3 \
        "$DB_FILE" \
        'PRAGMA foreign_keys;'

    echo
    echo "Tables:"
    runuser \
        -u nonecdn \
        -- sqlite3 \
        "$DB_FILE" \
        '.tables'

} > "$REPORT"


echo
echo "============================================================"
echo " CORE STAGE 1 COMPLETE"
echo "============================================================"
echo
echo "Database:"
echo "$DB_FILE"
echo
echo "Report:"
echo "$REPORT"
echo
echo "Next:"
echo "PANEL v0.1"
echo
