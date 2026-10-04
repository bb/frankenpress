#!/usr/bin/env bash
# FrankenPress cron runner, started in the background by the entrypoint
# (CRON, on by default): runs due WP-Cron events every CRON_INTERVAL seconds
# (default 60). WordPress itself only runs them when a page request reaches
# PHP, which cached pages never do, so scheduled posts, plugin jobs and
# automatic updates would wait for an uncached visit. The image sets
# DISABLE_WP_CRON while this runs, so page loads don't start wp-cron.php.
#
# Output goes to the container log, prefixed "FrankenPress cron:". A site
# that isn't installed yet (or whose database is unreachable) is skipped
# silently until it is.
interval=${CRON_INTERVAL:-60}

while sleep "$interval"; do
    wp core is-installed --skip-plugins --skip-themes 2>/dev/null || continue
    # Without --skip-plugins: the events' commands inherit the global flags,
    # and plugin events need their plugins loaded
    wp eval-file /usr/local/share/frankenpress/cron.php 2>&1 \
        | sed -u 's/^/FrankenPress cron: /'
done
