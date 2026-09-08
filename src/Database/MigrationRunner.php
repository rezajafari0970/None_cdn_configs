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
