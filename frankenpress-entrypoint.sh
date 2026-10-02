#!/usr/bin/env bash
# FrankenPress entrypoint: optionally repairs ownership of mounted folders,
# then hands over to the official WordPress entrypoint.
#
# The image runs as $FRANKENPRESS_USER (www-data) by default and this script
# does nothing extra. Bind mounts and some platforms (e.g. AWS ECS) hand the
# container root-owned folders, so uploads or Caddy's certificate storage
# aren't writable. For that case, start the container as root with
# FIX_PERMISSIONS=1: files not owned by the web user get chowned, then the
# process drops to that user for good.
set -euo pipefail

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
