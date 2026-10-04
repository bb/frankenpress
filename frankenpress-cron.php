<?php
/**
 * Runs due WP-Cron events for the FrankenPress cron runner (cron.sh), via
 * `wp eval-file`. Prints the events that ran and any errors; quiet otherwise.
 *
 * Only one container runs a site's events at a time: replicas sharing a
 * database would otherwise run the same events twice, because
 * `wp cron event run` ignores WordPress's own doing_cron lock. The database
 * lock is keyed by database and table prefix, so other sites on the same
 * server don't wait for each other, and it ends with the connection, so a
 * killed run doesn't leave it behind.
 */

global $wpdb;

$frankenpress_lock = 'frankenpress_cron_' . md5(DB_NAME . $wpdb->base_prefix);
if ('1' !== (string) $wpdb->get_var($wpdb->prepare('SELECT GET_LOCK(%s, 0)', $frankenpress_lock))) {
    return; // another container is running this site's events
}

// Multisite: every active site has its own events; --url selects the site
$frankenpress_urls = [null];
if (is_multisite()) {
    $frankenpress_urls = array_map('get_home_url', get_sites([
        'fields' => 'ids',
        'number' => 0,
        'archived' => 0,
        'deleted' => 0,
        'spam' => 0,
    ]));
}

foreach ($frankenpress_urls as $frankenpress_url) {
    $frankenpress_result = WP_CLI::runcommand(
        'cron event run --due-now' . (null === $frankenpress_url ? '' : ' --url=' . escapeshellarg($frankenpress_url)),
        ['launch' => true, 'exit_error' => false, 'return' => 'all']
    );
    // Keep "Executed the cron event ..." lines; drop the summary
    // ("Success: Executed a total of N cron events.")
    foreach (preg_split('/\R/', trim($frankenpress_result->stdout)) as $frankenpress_line) {
        if ('' !== $frankenpress_line && 0 !== strpos($frankenpress_line, 'Success: ')) {
            echo $frankenpress_line, "\n";
        }
    }
    if ('' !== trim($frankenpress_result->stderr)) {
        fwrite(STDERR, trim($frankenpress_result->stderr) . "\n");
    }
}

$wpdb->query($wpdb->prepare('SELECT RELEASE_LOCK(%s)', $frankenpress_lock));
