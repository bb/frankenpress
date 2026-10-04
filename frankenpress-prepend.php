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
 * except DISALLOW_FILE_EDIT, CORE_UPGRADE_SKIP_NEW_BUNDLED,
 * DISALLOW_PLUGIN_THEME_INSTALL and DISABLE_APPLICATION_PASSWORDS, which are
 * on unless set to 0/false/no/off, and DISABLE_WP_CRON, which follows CRON.
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

// DISABLE_WP_CRON: page loads don't start wp-cron.php. It follows CRON (the
// image's own cron runner, on by default; see frankenpress-cron.sh) unless
// set explicitly: =1 for an external scheduler with CRON=0, =0 to keep
// page-load cron next to the runner. Defined late like the settings below,
// so a site's own define wins.
$frankenpress_no_page_cron = $frankenpress_enabled('DISABLE_WP_CRON')
    || (!$frankenpress_disabled('DISABLE_WP_CRON') && !$frankenpress_disabled('CRON'));
if ($frankenpress_no_page_cron) {
    $GLOBALS['wp_filter']['muplugins_loaded'][10][] = [
        'function' => static function (): void {
            if (!defined('DISABLE_WP_CRON')) {
                define('DISABLE_WP_CRON', true);
            }
        },
        'accepted_args' => 0,
    ];
}
unset($frankenpress_no_page_cron);

// Settings that are on by default; NAME=0 turns each off:
// - DISALLOW_FILE_EDIT: no theme and plugin code editors in wp-admin, so a
//   stolen admin login can't be turned into running arbitrary PHP through
//   them. WordPress only reads it when checking capabilities.
// - CORE_UPGRADE_SKIP_NEW_BUNDLED: core updates don't install new default
//   themes and plugins into wp-content.
//
// Many sites define these constants in WORDPRESS_CONFIG_EXTRA already. This
// file runs before wp-config.php, so defining them here would make their
// define() warn "Constant already defined". Instead, pre-register a callback
// on muplugins_loaded, which WordPress runs after wp-config.php: it only
// defines a constant if the site didn't. WordPress picks up hooks placed
// in $wp_filter before it loads (WP_Hook::build_preinitialized_hooks), so
// this needs no mu-plugin in the volume and works for existing sites.
foreach (['DISALLOW_FILE_EDIT', 'CORE_UPGRADE_SKIP_NEW_BUNDLED'] as $frankenpress_name) {
    if (!$frankenpress_disabled($frankenpress_name)) {
        $GLOBALS['wp_filter']['muplugins_loaded'][10][] = [
            'function' => static function () use ($frankenpress_name): void {
                if (!defined($frankenpress_name)) {
                    define($frankenpress_name, true);
                }
            },
            'accepted_args' => 0,
        ];
    }
}
unset($frankenpress_name);

// Settings that are on by default and work through WordPress filters rather
// than constants, registered the same way; NAME=0 turns each off:
// - DISALLOW_PLUGIN_THEME_INSTALL: nobody can install or upload plugins and
//   themes through wp-admin or the REST API, so a stolen admin session can't
//   upload a plugin carrying a web shell. Updates (automatic and from
//   wp-admin), activation and deletion still work, and so does
//   `wp plugin install`, since WP-CLI doesn't check capabilities.
// - DISABLE_APPLICATION_PASSWORDS: no application passwords, so a stolen
//   admin session can't create a password for the REST API that outlives
//   it. Existing application passwords stop working too.
if (!$frankenpress_disabled('DISALLOW_PLUGIN_THEME_INSTALL')) {
    $GLOBALS['wp_filter']['map_meta_cap'][10][] = [
        'function' => static function ($caps, $cap) {
            return in_array($cap, ['install_plugins', 'upload_plugins', 'install_themes', 'upload_themes'], true)
                ? ['do_not_allow']
                : $caps;
        },
        'accepted_args' => 2,
    ];
}
if (!$frankenpress_disabled('DISABLE_APPLICATION_PASSWORDS')) {
    $GLOBALS['wp_filter']['wp_is_application_passwords_available'][10][] = [
        'function' => static function (): bool {
            return false;
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
