<?php

declare(strict_types=1);

namespace NoneCDN\Database;

use PDO;

interface Migration
{
    public function version(): string;

    public function up(PDO $pdo): void;
}
