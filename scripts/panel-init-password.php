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
