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
