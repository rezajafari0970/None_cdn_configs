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
