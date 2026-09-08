<?php
declare(strict_types=1);

namespace NoneCDN\Panel;

final class Csrf
{
    public static function token(): string
    {
        if (empty($_SESSION['csrf'])) {
            $_SESSION['csrf'] =
                bin2hex(random_bytes(32));
        }

        return $_SESSION['csrf'];
    }

    public static function validate(
        ?string $token
    ): bool {
        if (
            empty($_SESSION['csrf']) ||
            !$token
        ) {
            return false;
        }

        return hash_equals(
            $_SESSION['csrf'],
            $token
        );
    }
}
