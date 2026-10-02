#!/bin/sh
# Runs a MariaDB client tool (installed as /usr/local/bin/mariadb,
# mariadb-dump, mysql, ...) without TLS certificate verification, the way
# WordPress itself connects.
#
# MariaDB's client verifies the server certificate by default since 11.4.
# That fails against MySQL and MariaDB servers before 11.4 ("SSL is required,
# but the server does not support it", "self-signed certificate in
# certificate chain"), which breaks `wp db`. WP-CLI's db-command adds
# --skip-ssl-verify-server-cert itself from version 3.0, but WP-CLI 2.12
# bundles an older one. TLS is still used when the server offers it, and a
# later --ssl-verify-server-cert on the command line turns verification on.
tool=/usr/bin/$(basename "$0")
case "${1:-}" in
    # Option-file options must come first
    --no-defaults|--defaults-file=*|--defaults-extra-file=*|--defaults-group-suffix=*)
        first=$1
        shift
        exec "$tool" "$first" --skip-ssl-verify-server-cert "$@"
        ;;
esac
exec "$tool" --skip-ssl-verify-server-cert "$@"
