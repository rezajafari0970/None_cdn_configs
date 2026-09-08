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
