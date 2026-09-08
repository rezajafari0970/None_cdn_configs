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
