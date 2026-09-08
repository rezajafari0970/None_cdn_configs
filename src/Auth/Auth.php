<?php
declare(strict_types=1);

namespace NoneCDN\Auth;

final class Auth
{
    private const HASH_FILE =
        '/var/lib/nonecdn/state/admin-password.hash';

    public static function initialized(): bool
    {
        return is_file(self::HASH_FILE);
    }

    public static function setPassword(string $password): void
    {
        if (strlen($password) < 10) {
            throw new \InvalidArgumentException(
                'Password must contain at least 10 characters.'
            );
        }

        $hash = password_hash(
            $password,
            PASSWORD_DEFAULT
        );

        if (!$hash) {
            throw new \RuntimeException(
                'Password hashing failed.'
            );
        }

        if (file_put_contents(
            self::HASH_FILE,
            $hash,
            LOCK_EX
        ) === false) {
            throw new \RuntimeException(
                'Unable to write password hash.'
            );
        }

        chmod(self::HASH_FILE, 0640);
    }

    public static function verify(string $password): bool
    {
        if (!self::initialized()) {
            return false;
        }

        $hash = trim(
            (string)file_get_contents(
                self::HASH_FILE
            )
        );

        return password_verify(
            $password,
            $hash
        );
    }

    public static function login(): void
    {
        session_regenerate_id(true);

        $_SESSION['authenticated'] = true;
        $_SESSION['authenticated_at'] = time();
    }

    public static function logout(): void
    {
        $_SESSION = [];

        if (session_id() !== '') {
            session_destroy();
        }
    }

    public static function check(): bool
    {
        return !empty(
            $_SESSION['authenticated']
        );
    }
}
