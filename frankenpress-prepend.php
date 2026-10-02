<?php
/**
 * FrankenPress runtime settings, loaded before every PHP script through
 * auto_prepend_file (see php.ini).
 *
 * These live here rather than in wp-config.php because the official
 * WordPress entrypoint writes wp-config.php only once, when a site is first
 * created. Settings in this file therefore reach new and existing sites alike.
 *
 * Switches accept 1/true/yes/on (case-insensitive); anything else is off.
 * Don't also define DISALLOW_FILE_EDIT or DISABLE_WP_CRON in
 * WORDPRESS_CONFIG_EXTRA, or PHP warns that the constant is already defined.
 */

$frankenpress_enabled = static function (string $name): bool {
    return in_array(strtolower((string) getenv($name)), ['1', 'true', 'yes', 'on'], true);
};

// HTTPS: forced via FORCE_HTTPS, or marked by Caddy when a trusted proxy
// forwarded the request as HTTPS (clients can't set the marker themselves;
// Caddy strips it from incoming requests).
if (PHP_SAPI !== 'cli'
    && ($frankenpress_enabled('FORCE_HTTPS') || ($_SERVER['HTTP_X_FRANKENPRESS_HTTPS'] ?? '') === 'on')) {
    $_SERVER['HTTPS'] = 'on';
}

// Turn off the theme and plugin code editors in wp-admin, so a stolen admin
// login can't be turned into running arbitrary PHP through them.
if ($frankenpress_enabled('DISALLOW_FILE_EDIT') && !defined('DISALLOW_FILE_EDIT')) {
    define('DISALLOW_FILE_EDIT', true);
}

// Stop WordPress from running cron on page loads; use with a real scheduler,
// e.g. `wp cron event run --due-now` every few minutes.
if ($frankenpress_enabled('DISABLE_WP_CRON') && !defined('DISABLE_WP_CRON')) {
    define('DISABLE_WP_CRON', true);
}

unset($frankenpress_enabled);
