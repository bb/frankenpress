#!/usr/bin/env bash
# FrankenPress entrypoint: applies UMASK, logs the mail setup, optionally
# repairs ownership of mounted folders, then hands over to the official
# WordPress entrypoint.
#
# UMASK (e.g. 0002) sets the file creation mask for FrankenPHP, PHP and
# everything they start, for sites that share wp-content with another user
# through a common group. Unset keeps the default (0022).
#
# The image runs as $FRANKENPRESS_USER (www-data) by default and this script
# does nothing extra. Bind mounts and some platforms (e.g. AWS ECS) hand the
# container root-owned folders, so uploads or Caddy's certificate storage
# aren't writable. For that case, start the container as root with
# FIX_OWNERSHIP=1: files not owned by the web user get chowned, then the
# process drops to that user for good.
set -euo pipefail

# FIX_OWNERSHIP was briefly called FIX_PERMISSIONS (it only ever changed
# ownership). Stop loudly instead of silently skipping the repair.
if [ -n "${FIX_PERMISSIONS:-}" ]; then
    echo "FrankenPress: FIX_PERMISSIONS has been renamed to FIX_OWNERSHIP (it changes ownership, not permissions); set FIX_OWNERSHIP=1 instead" >&2
    exit 1
fi

if [ -n "${UMASK:-}" ]; then
    if [[ ! "$UMASK" =~ ^[0-7]{3,4}$ ]]; then
        echo "FrankenPress: invalid UMASK '$UMASK'; use three or four octal digits, e.g. 0002" >&2
        exit 1
    fi
    umask "$UMASK"
fi

# PHP_INI: php.ini lines from the environment, written to the file PHP reads
# last, so they win over the image's settings. The file persists for the
# container's life, so `docker exec … wp` sees them too. PHP reports syntax
# errors and invalid values but ignores unknown setting names, so those are
# checked here: a typo stops the container instead of silently not applying.
ini_file="$PHP_INI_DIR/conf.d/zz-frankenpress-env.ini"
if [ -w "$ini_file" ]; then
    printf '%s\n' "${PHP_INI:-}" >"$ini_file"
elif [ -n "${PHP_INI:-}" ]; then
    echo "FrankenPress: can't write PHP_INI to $ini_file; is the container running as a user other than ${FRANKENPRESS_USER:-www-data}, or with a read-only filesystem?" >&2
    exit 1
fi
if [ -n "${PHP_INI:-}${UPLOAD_MAX_SIZE:-}" ]; then
    names=$(sed -nE 's/^[[:space:]]*([A-Za-z0-9_.]+)[[:space:]]*=.*/\1/p' <<<"${PHP_INI:-}" | grep -vxE 'extension|zend_extension' || true)
    # shellcheck disable=SC2086 # names only contain [A-Za-z0-9_.]
    problems=$(php -r 'foreach (array_slice($argv, 1) as $n) if (ini_get($n) === false) echo "unknown PHP setting \"$n\"\n";' -- $names 2>&1)
    if [ -n "$problems" ]; then
        echo "FrankenPress: PHP_INI or UPLOAD_MAX_SIZE isn't valid:" >&2
        echo "$problems" >&2
        exit 1
    fi
fi

# Caddy refuses larger request bodies before PHP sees them. Unless
# REQUEST_BODY_MAX_BYTES is set, follow PHP's effective post_max_size, so
# raising it (UPLOAD_MAX_SIZE, PHP_INI or a mounted .ini) doesn't leave a
# 413 from Caddy in the way. post_max_size 0 means no limit.
if [[ "${1:-}" == frankenphp* ]] && [ -z "${REQUEST_BODY_MAX_BYTES:-}" ]; then
    limits=$(php -r 'echo ini_parse_quantity(ini_get("post_max_size")), " ", ini_get("post_max_size"), " ", ini_get("upload_max_filesize");' 2>/dev/null || true)
    read -r bytes post upload <<<"$limits"
    if [[ "${bytes:-}" =~ ^[0-9]+$ ]]; then
        [ "$bytes" -gt 0 ] || bytes=9223372036854775807
        export REQUEST_BODY_MAX_BYTES=$bytes
        if [ "$bytes" != 536870912 ]; then
            echo "FrankenPress: uploads up to $upload, request bodies up to $post (upload_max_filesize, post_max_size)"
        fi
    fi
fi

# PHP threads: FrankenPHP starts two per CPU it sees, e.g. 64 on an
# unlimited 32-thread host, each allowed memory_limit. Default to two per
# available CPU (CPU limit or cpuset), but at most 4. num_threads in
# FRANKENPHP_CONFIG takes precedence; so do workers, whose thread count
# FrankenPHP has to size itself.
if [[ "${1:-}" == frankenphp* ]] && ! grep -qE '^[[:space:]]*(num_threads|worker)([[:space:]]|$)' <<<"${FRANKENPHP_CONFIG:-}"; then
    cpus=$(nproc)
    quota=max
    if [ -r /sys/fs/cgroup/cpu.max ]; then
        read -r quota period </sys/fs/cgroup/cpu.max
    elif [ -r /sys/fs/cgroup/cpu/cpu.cfs_quota_us ]; then # cgroup v1
        quota=$(cat /sys/fs/cgroup/cpu/cpu.cfs_quota_us)
        period=$(cat /sys/fs/cgroup/cpu/cpu.cfs_period_us)
    fi
    if [[ "$quota" =~ ^[0-9]+$ ]] && [ "$quota" -gt 0 ]; then
        limit=$(( (quota + period - 1) / period ))
        [ "$limit" -lt "$cpus" ] && cpus=$limit
    fi
    threads=$(( 2 * cpus < 4 ? 2 * cpus : 4 ))
    # max_threads below the default would make FrankenPHP refuse to start
    max=$(grep -oE '^[[:space:]]*max_threads[[:space:]]+[0-9]+' <<<"${FRANKENPHP_CONFIG:-}" | grep -oE '[0-9]+$' || true)
    if [ -n "$max" ] && [ "$max" -lt "$threads" ]; then
        threads=$max
    fi
    export FRANKENPHP_CONFIG="num_threads $threads
${FRANKENPHP_CONFIG:-}"
    echo "FrankenPress: $threads PHP threads (2 per CPU, at most 4; set num_threads in FRANKENPHP_CONFIG to change)"
fi

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
    if [ -n "${UMASK:-}" ]; then
        echo "FrankenPress: umask $UMASK"
    fi
fi

# WP-Cron runner (CRON, on by default; 0/false/no/off turns it off): runs
# due events every CRON_INTERVAL seconds in the background, see
# frankenpress-cron.sh. Only with the server, never for one-off commands.
cron=0
if [[ "${1:-}" == frankenphp* ]] && [[ ! "${CRON:-}" =~ ^(0|[Ff][Aa][Ll][Ss][Ee]|[Nn][Oo]|[Oo][Ff][Ff])$ ]]; then
    if [[ ! "${CRON_INTERVAL:-60}" =~ ^[1-9][0-9]*$ ]]; then
        echo "FrankenPress: invalid CRON_INTERVAL '${CRON_INTERVAL}'; use a number of seconds, e.g. 60" >&2
        exit 1
    fi
    cron=1
    echo "FrankenPress: WP-Cron runs every ${CRON_INTERVAL:-60}s in the container (CRON=0 turns it off)"
fi

if [ "$(id -u)" = 0 ] && [ "${FIX_OWNERSHIP:-0}" = 1 ]; then
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

    if [ "$cron" = 1 ]; then
        setpriv --reuid="$user" --regid="$group" --init-groups -- \
            /usr/local/share/frankenpress/cron.sh &
    fi
    exec setpriv --reuid="$user" --regid="$group" --init-groups -- \
        /usr/local/bin/docker-entrypoint.sh "$@"
fi

if [ "$cron" = 1 ]; then
    /usr/local/share/frankenpress/cron.sh &
fi
exec /usr/local/bin/docker-entrypoint.sh "$@"
