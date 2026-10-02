<?php
/**
 * FrankenPress runtime settings, loaded before every PHP script through
 * auto_prepend_file (see php.ini).
 *
 * These live here rather than in wp-config.php because the official
 * WordPress entrypoint writes wp-config.php only once, when a site is first
 * created. Settings in this file therefore reach new and existing sites alike.
 *
 * Switches accept 1/true/yes/on (case-insensitive); anything else is off,
 * except CORE_UPGRADE_SKIP_NEW_BUNDLED, which is on unless set to
 * 0/false/no/off.
 * Don't also define DISALLOW_FILE_EDIT or DISABLE_WP_CRON in
 * WORDPRESS_CONFIG_EXTRA, or PHP warns that the constant is already defined.
 */

$frankenpress_enabled = static function (string $name): bool {
    return in_array(strtolower((string) getenv($name)), ['1', 'true', 'yes', 'on'], true);
};
$frankenpress_disabled = static function (string $name): bool {
    return in_array(strtolower((string) getenv($name)), ['0', 'false', 'no', 'off'], true);
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

// Core updates shouldn't install new default themes and plugins into
// wp-content (WordPress's CORE_UPGRADE_SKIP_NEW_BUNDLED). On by default;
// CORE_UPGRADE_SKIP_NEW_BUNDLED=0 turns it off.
//
// Many sites define this constant in WORDPRESS_CONFIG_EXTRA already. This
// file runs before wp-config.php, so defining it here would make their
// define() warn "Constant already defined". Instead, pre-register a callback
// on muplugins_loaded, which WordPress runs after wp-config.php: it only
// defines the constant if the site didn't. WordPress picks up hooks placed
// in $wp_filter before it loads (WP_Hook::build_preinitialized_hooks), so
// this needs no mu-plugin in the volume and works for existing sites.
if (!$frankenpress_disabled('CORE_UPGRADE_SKIP_NEW_BUNDLED')) {
    $GLOBALS['wp_filter']['muplugins_loaded'][10][] = [
        'function' => static function (): void {
            if (!defined('CORE_UPGRADE_SKIP_NEW_BUNDLED')) {
                define('CORE_UPGRADE_SKIP_NEW_BUNDLED', true);
            }
        },
        'accepted_args' => 0,
    ];
}

// UMASK (e.g. 0002), for sites sharing wp-content with another user through
// a common group. The entrypoint sets it for the server and everything it
// starts; this covers the rest:
// - `docker exec ... wp` and other PHP CLI runs, which start with Docker's
//   default umask instead of the entrypoint's
// - plugin, theme and core updates, which WordPress writes with explicit
//   permissions (FS_CHMOD_FILE/FS_CHMOD_DIR, by default derived from
//   index.php and ABSPATH) instead of the umask. They're derived from UMASK
//   here, if the site doesn't define them itself, in the same
//   muplugins_loaded hook as above. Folders keep the setgid bit when
//   wp-content has it, because a chmod without it clears it, and the other
//   user's files in new folders would then lose the shared group.
// Uploads take the permissions of their folder, so setgid 2775 folders
// already give 664 uploads.
$frankenpress_umask = getenv('UMASK');
if (is_string($frankenpress_umask) && preg_match('/^[0-7]{3,4}$/', $frankenpress_umask)) {
    $frankenpress_mask = octdec($frankenpress_umask);
    if (PHP_SAPI === 'cli') {
        umask($frankenpress_mask);
    }
    $GLOBALS['wp_filter']['muplugins_loaded'][10][] = [
        'function' => static function () use ($frankenpress_mask): void {
            if (!defined('FS_CHMOD_FILE')) {
                define('FS_CHMOD_FILE', 0666 & ~$frankenpress_mask);
            }
            if (!defined('FS_CHMOD_DIR')) {
                $setgid = (defined('WP_CONTENT_DIR') && (@fileperms(WP_CONTENT_DIR) & 02000)) ? 02000 : 0;
                define('FS_CHMOD_DIR', (0777 & ~$frankenpress_mask) | $setgid);
            }
        },
        'accepted_args' => 0,
    ];
    unset($frankenpress_mask);
}

unset($frankenpress_enabled, $frankenpress_disabled, $frankenpress_umask);
