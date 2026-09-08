<?php

declare(strict_types=1);

spl_autoload_register(
    static function (string $class): void {
        $prefix = 'NoneCDN\\';

        if (!str_starts_with(
            $class,
            $prefix
        )) {
            return;
        }

        $relative = substr(
            $class,
            strlen($prefix)
        );

        $base = '/opt/nonecdn/src/';

        $file =
            $base .
            str_replace(
                '\\',
                '/',
                $relative
            ) .
            '.php';

        if (is_file($file)) {
            require $file;
            return;
        }

        $migrationBase =
            '/opt/nonecdn/migrations/';

        if (str_starts_with(
            $relative,
            'Migrations\\'
        )) {
            $name = substr(
                $relative,
                strlen('Migrations\\')
            );

            $migrationFile =
                $migrationBase .
                str_replace(
                    '\\',
                    '/',
                    $name
                ) .
                '.php';

            if (is_file($migrationFile)) {
                require $migrationFile;
            }
        }
    }
);
