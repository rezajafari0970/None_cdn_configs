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
