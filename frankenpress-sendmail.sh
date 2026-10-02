#!/usr/bin/env bash
# sendmail for FrankenPress: hands each message to msmtp, configured from
# MSMTP_* environment variables at send time, so there's no config file with
# the password in it and changes apply without a restart.
#
# Installed as /usr/sbin/sendmail, which PHP's mail() (and so WordPress)
# calls as `sendmail -t -i`.
#
#   MSMTP            off disables mail (sending fails with a message)
#   MSMTP_HOST       SMTP relay; without it, sending fails with a message
#   MSMTP_PORT       default 587
#   MSMTP_USER       login; enables authentication
#   MSMTP_PASSWORD   password for MSMTP_USER (never put on the command line)
#   MSMTP_FROM       envelope sender; default: taken from the message's From:
#   MSMTP_TLS        on (default) / off
#   MSMTP_STARTTLS   on / off; default on, except off for port 465 (implicit TLS)
#   MSMTP_AUTH       on / off / a method (plain, login, ...); default on
#                    when MSMTP_USER is set, off otherwise
#   MSMTP_TLS_CERTCHECK  on (default) / off, for relays with self-signed certs
#   MSMTP_SET_FROM_HEADER  on replaces the message's From: with the envelope
#                    sender (for relays that reject a From: other than the
#                    login); default auto (only adds one when missing)
#
# Every variable also has a _FILE variant (e.g. MSMTP_PASSWORD_FILE=
# /run/secrets/smtp_password) for Docker secrets, like the official WordPress
# image's WORDPRESS_*_FILE; setting both is an error.
#
# Each delivery is logged to stderr, so it shows up in the container log
# ("MSMTP ..." lines) without mixing into the output of commands like wp.
set -euo pipefail

# Resolve X_FILE into X for every setting except the password, which msmtp
# reads from the file itself below
for var in MSMTP MSMTP_HOST MSMTP_PORT MSMTP_USER MSMTP_FROM MSMTP_TLS MSMTP_STARTTLS \
           MSMTP_AUTH MSMTP_TLS_CERTCHECK MSMTP_SET_FROM_HEADER MSMTP_PASSWORD; do
    file_var="${var}_FILE"
    if [ -n "${!var:-}" ] && [ -n "${!file_var:-}" ]; then
        echo "sendmail: both $var and $file_var are set (but are exclusive)" >&2
        exit 1
    fi
    if [ "$var" != MSMTP_PASSWORD ] && [ -n "${!file_var:-}" ]; then
        if [ ! -r "${!file_var}" ]; then
            echo "sendmail: $file_var points to ${!file_var}, which isn't readable" >&2
            exit 1
        fi
        printf -v "$var" '%s' "$(< "${!file_var}")"
    fi
done

if [ "${MSMTP:-on}" = off ]; then
    echo "sendmail: mail is disabled (MSMTP=off)" >&2
    exit 1
fi

if [ -z "${MSMTP_HOST:-}" ]; then
    echo "sendmail: no SMTP relay configured; set MSMTP_HOST (and usually MSMTP_USER, MSMTP_PASSWORD, MSMTP_FROM), or MSMTP=off to disable mail" >&2
    exit 1
fi

port="${MSMTP_PORT:-587}"
if [ -n "${MSMTP_STARTTLS:-}" ]; then
    starttls="$MSMTP_STARTTLS"
elif [ "$port" = 465 ]; then
    starttls=off
else
    starttls=on
fi

args=(
    --host="$MSMTP_HOST"
    --port="$port"
    --tls="${MSMTP_TLS:-on}"
    --tls-starttls="$starttls"
    --tls-certcheck="${MSMTP_TLS_CERTCHECK:-on}"
    --tls-trust-file=/etc/ssl/certs/ca-certificates.crt
    --logfile=/dev/stderr
    --logfile-time-format="%FT%T MSMTP"
)

if [ -n "${MSMTP_USER:-}" ]; then
    # msmtp reads the password itself, from the environment or the secret
    # file, so it never appears on a command line or in the process list.
    if [ -n "${MSMTP_PASSWORD_FILE:-}" ]; then
        if [ ! -r "$MSMTP_PASSWORD_FILE" ]; then
            echo "sendmail: MSMTP_PASSWORD_FILE points to $MSMTP_PASSWORD_FILE, which isn't readable" >&2
            exit 1
        fi
        passwordeval='cat "$MSMTP_PASSWORD_FILE"'
    else
        passwordeval='printenv MSMTP_PASSWORD'
    fi
    args+=(--auth="${MSMTP_AUTH:-on}" --user="$MSMTP_USER" --passwordeval="$passwordeval")
else
    args+=(--auth="${MSMTP_AUTH:-off}")
fi

if [ -n "${MSMTP_FROM:-}" ]; then
    args+=(--from="$MSMTP_FROM")
else
    args+=(--read-envelope-from)
fi
args+=(--set-from-header="${MSMTP_SET_FROM_HEADER:-auto}")

# Arguments from the caller come last, so e.g. `-f sender` still wins
exec /usr/bin/msmtp "${args[@]}" "$@"
