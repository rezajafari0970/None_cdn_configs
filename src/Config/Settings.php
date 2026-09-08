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
