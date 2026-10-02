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

if (PHP_SAPI !== 'cli') {
    // Forwarded-protocol headers only count from trusted proxies. Caddy says
    // whether the request came from one (TRUSTED_PROXIES) in a server
    // variable no client header can produce. Without this, WordPress's stock
    // wp-config.php would treat any visitor sending X-Forwarded-Proto: https
    // as HTTPS. $_SERVER keys are normalized, so this covers every "-"/"_"
    // spelling of the headers.
    if (($_SERVER['FRANKENPRESS_TRUSTED_PROXY'] ?? '') !== 'true') {
        unset($_SERVER['HTTP_X_FORWARDED_PROTO'], $_SERVER['HTTP_CLOUDFRONT_FORWARDED_PROTO']);
    }

    // Older images passed the HTTPS decision as an X-Frankenpress-Https
    // header, and sites created with them check it in wp-config.php. It's
    // never legitimate now, so drop any client-sent copy.
    unset($_SERVER['HTTP_X_FRANKENPRESS_HTTPS']);

    // HTTPS: forced via FORCE_HTTPS, or decided by Caddy when a trusted proxy
    // forwarded the request as HTTPS
    if ($frankenpress_enabled('FORCE_HTTPS') || ($_SERVER['FRANKENPRESS_HTTPS'] ?? '') === 'on') {
        $_SERVER['HTTPS'] = 'on';
    }
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
