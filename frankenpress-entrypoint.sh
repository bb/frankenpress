#!/usr/bin/env bash
# FrankenPress entrypoint: logs the mail setup, optionally repairs ownership
# of mounted folders, then hands over to the official WordPress entrypoint.
#
# The image runs as $FRANKENPRESS_USER (www-data) by default and this script
# does nothing extra. Bind mounts and some platforms (e.g. AWS ECS) hand the
# container root-owned folders, so uploads or Caddy's certificate storage
# aren't writable. For that case, start the container as root with
# FIX_PERMISSIONS=1: files not owned by the web user get chowned, then the
# process drops to that user for good.
set -euo pipefail

# Say once at server start where mail goes, so a missing relay isn't silent
# (WordPress would otherwise fail every wp_mail() without telling anyone).
if [[ "${1:-}" == frankenphp* ]]; then
    if [ "${MSMTP:-on}" = off ]; then
        echo "FrankenPress: mail is disabled (MSMTP=off)"
    elif [ -n "${MSMTP_HOST:-}${MSMTP_HOST_FILE:-}" ]; then
        echo "FrankenPress: mail is sent via ${MSMTP_HOST:-<MSMTP_HOST_FILE>}:${MSMTP_PORT:-587}"
    else
        echo "FrankenPress: mail is NOT configured; WordPress can't send email until MSMTP_HOST is set (or set MSMTP=off to disable mail)" >&2
    fi
fi

if [ "$(id -u)" = 0 ] && [ "${FIX_PERMISSIONS:-0}" = 1 ]; then
    user="${FRANKENPRESS_USER:-www-data}"
    group="$(id -gn "$user")"

    for dir in /var/www/html /data/caddy /config/caddy; do
        [ -d "$dir" ] || continue
        echo "FrankenPress: fixing ownership in $dir"
        # Only touch what's wrong, so large upload folders don't slow every
        # start. -h changes symlinks themselves: following one could hand a
        # file outside the volume to the web user.
        find "$dir" \( ! -user "$user" -o ! -group "$group" \) -exec chown -h "$user:$group" {} +
    done

    exec setpriv --reuid="$user" --regid="$group" --init-groups -- \
        /usr/local/bin/docker-entrypoint.sh "$@"
fi

exec /usr/local/bin/docker-entrypoint.sh "$@"
