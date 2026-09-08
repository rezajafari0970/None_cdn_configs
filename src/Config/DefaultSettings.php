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
