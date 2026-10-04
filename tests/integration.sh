#!/usr/bin/env bash
# Integration test for a built FrankenPress image.
#
# Usage: tests/integration.sh <image> <standard|vips-ffi>
#
# Starts MariaDB and the image, installs WordPress, then checks runtime health,
# the hardening rules, proxy handling and image processing. Needs Docker and
# curl, jq and python3; exits non-zero if any check fails.
set -u
IMG=$1; VARIANT=$2; NET=fpt-$$; WP=fpwp-$$; WP2=fpwp2-$$; WP3=fpwp3-$$; TH=fpthreads-$$; DB=fpdb-$$; DBOLD=fpdbold-$$; MAIL=fpmail-$$; PORT=${PORT:-18081}
fail=0
check() { # check <description> <expected> <actual>
  if [ "$2" = "$3" ]; then printf "  ok    %-52s %s\n" "$1" "$3"; else printf "  FAIL  %-52s expected=%s got=%s\n" "$1" "$2" "$3"; fail=1; fi
}
cleanup() { docker rm -fv $WP $WP2 $WP3 $TH $DB $DBOLD $MAIL >/dev/null 2>&1; docker network rm $NET >/dev/null 2>&1; }
trap cleanup EXIT

echo "=== $IMG ($VARIANT)"
# --- static checks
out=$(docker run --rm "$IMG" php -v 2>&1)
check "php -v without warnings" 0 "$(grep -ciE 'warning|unable to load' <<<"$out")"
for p in git unzip libnss3-tools; do
  check "package $p removed" no "$(docker run --rm --entrypoint sh "$IMG" -c "dpkg -s $p 2>/dev/null | grep -q '^Status: install ok installed' && echo yes || echo no")"
done
check "ImageMagick extra coders not installed" no "$(docker run --rm --entrypoint sh "$IMG" -c "dpkg -s libmagickcore-7.q16-10-extra 2>/dev/null | grep -q '^Status: install ok installed' && echo yes || echo no")"
missing=$(docker run --rm --entrypoint sh "$IMG" -c 'for f in $(php -r "echo ini_get(\"extension_dir\");")/*.so; do ldd "$f" | grep "not found"; done' 2>&1 | wc -l | tr -d ' ')
check "all extension libraries resolve (ldd)" 0 "$missing"
for t in mariadb mariadb-dump mariadb-import; do
  check "$t works" yes "$(docker run --rm --entrypoint $t "$IMG" --version 2>/dev/null | grep -q 'from 1[0-9]\.' && echo yes || echo no)"
done
check "wp-cli works" yes "$(docker run --rm "$IMG" wp --version 2>/dev/null | grep -q '^WP-CLI [0-9]' && echo yes || echo no)"
check "opcache.max_accelerated_files" 20000 "$(docker run --rm "$IMG" php -r 'echo ini_get("opcache.max_accelerated_files");')"
check "memory_limit" 256M "$(docker run --rm "$IMG" php -r 'echo ini_get("memory_limit");')"
check "real hostname uses ACME, not internal CA" "" "$(docker run --rm -e SERVER_NAME=example.com --entrypoint frankenphp "$IMG" adapt --config /etc/caddy/Caddyfile 2>/dev/null | grep -o '"module":"internal"')"
check "max_input_vars" 5000 "$(docker run --rm "$IMG" php -r 'echo ini_get("max_input_vars");')"

# PHP threads: two per available CPU, at most 4, unless FRANKENPHP_CONFIG
# sets num_threads. Read from FrankenPHP's own startup log line.
threads() { # threads <docker run options...> -> "num_threads/max_threads"
  local c=$TH out=""
  docker run -d --name $c "$@" "$IMG" >/dev/null
  for _ in $(seq 1 30); do
    out=$(docker logs $c 2>&1 | grep -o '"num_threads":[0-9]*,"max_threads":[0-9]*' | grep -oE '[0-9]+' | paste -sd/ -)
    [ -n "$out" ] && break; sleep 1
  done
  docker rm -f $c >/dev/null; echo "$out"
}
ncpu=$(docker info -f '{{.NCPU}}'); def=$(( 2 * ncpu < 4 ? 2 * ncpu : 4 ))
check "PHP threads without a limit ($ncpu CPUs)" "$def/$def" "$(threads)"
check "PHP threads with --cpus 1" 2/2 "$(threads --cpus 1)"
check "num_threads in FRANKENPHP_CONFIG wins" 3/3 "$(threads -e FRANKENPHP_CONFIG='num_threads 3')"
check "max_threads alone keeps the default start" "$def/8" "$(threads -e FRANKENPHP_CONFIG='max_threads 8')"

# FIX_OWNERSHIP: a root-owned volume (with a symlink planted in it) gets
# repaired at startup, then the process drops to www-data
VOL=fpvol-$$
docker volume create $VOL >/dev/null
docker run --rm -v $VOL:/data/caddy --entrypoint sh "$IMG" -c 'exit 0' >/dev/null 2>&1
docker run --rm --user root -v $VOL:/data/caddy --entrypoint sh "$IMG" -c 'mkdir -p /data/caddy/certs && touch /data/caddy/certs/x && ln -s /etc/shadow /data/caddy/link && chown -R root:root /data/caddy'
fix=$(docker run --rm --user root -e FIX_OWNERSHIP=1 -v $VOL:/data/caddy "$IMG" sh -c 'echo "$(id -un) $(stat -c %U /data/caddy/certs/x) $(stat -L -c %U /etc/shadow)"' 2>/dev/null | tail -1)
check "FIX_OWNERSHIP repairs ownership, drops to www-data" "www-data www-data root" "$fix"
check "old name FIX_PERMISSIONS stops with a message" "renamed to FIX_OWNERSHIP" "$(docker run --rm -e FIX_PERMISSIONS=1 "$IMG" 2>&1 | grep -o 'renamed to FIX_OWNERSHIP')"
docker volume rm $VOL >/dev/null

# --- runtime
docker network create $NET >/dev/null
# SMTP sink with an HTTP API, to check mail delivery
docker run -d --name $MAIL --network $NET -p $((PORT + 2)):8025 axllent/mailpit >/dev/null
docker run -d --name $DB --network $NET -e MARIADB_ROOT_PASSWORD=r -e MARIADB_DATABASE=wp -e MARIADB_USER=wp -e MARIADB_PASSWORD=wp mariadb:11 >/dev/null
# A server without TLS (MariaDB before 11.4), for the client tools below
docker run -d --name $DBOLD --network $NET -e MARIADB_ROOT_PASSWORD=r mariadb:10.11 >/dev/null
for _ in $(seq 1 40); do docker exec $DB mariadb -uwp -pwp -e 'select 1' wp >/dev/null 2>&1 && break; sleep 2; done
docker run -d --name $WP --network $NET -p $PORT:80 -e UMASK=0002 -e SUPERCACHE=1 -e HSTS=max-age=300 -e MSMTP_HOST=$MAIL -e MSMTP_PORT=1025 -e MSMTP_TLS=off -e MSMTP_FROM=noreply@site.example -e WORDPRESS_DB_HOST=$DB -e WORDPRESS_DB_USER=wp -e WORDPRESS_DB_PASSWORD=wp -e WORDPRESS_DB_NAME=wp "$IMG" >/dev/null
for _ in $(seq 1 30); do curl -s -o /dev/null http://localhost:$PORT/ && break; sleep 1; done
docker exec $WP wp core install --url=http://localhost:$PORT --title=T --admin_user=a --admin_password=a --admin_email=a@example.com --skip-email >/dev/null 2>&1
B=http://localhost:$PORT
code() { curl -s -o /dev/null -w '%{http_code}' "$B$1"; }
check "home page (default SERVER_NAME :80)" 200 "$(code /)"
check "public /healthz without PHP" ok "$(curl -s $B/healthz)"
check "Server header hidden" 0 "$(curl -sI $B/ | grep -ci '^server:')"
check "wp-login.php" 200 "$(code /wp-login.php)"
check "wp-admin css (static)" 200 "$(code /wp-admin/css/login.min.css)"

# MariaDB client: wp db round trip, and the tools against a server without
# TLS, which the client's default certificate verification would refuse
check "wp db query" 1 "$(docker exec $WP wp db query 'SELECT COUNT(*) FROM wp_users' --skip-column-names 2>/dev/null)"
docker exec $WP sh -c 'wp db export /tmp/db.sql >/dev/null 2>&1 && wp option update blogname changed >/dev/null 2>&1 && wp db import /tmp/db.sql >/dev/null 2>&1'
check "wp db export + import restore the site" T "$(docker exec $WP wp option get blogname 2>/dev/null)"
for _ in $(seq 1 40); do docker exec $DBOLD mariadb -uroot -pr -e 'select 1' >/dev/null 2>&1 && break; sleep 2; done
check "mariadb to a server without TLS" 1 "$(docker exec $WP sh -c "MYSQL_PWD=r mariadb -h $DBOLD -uroot -N -e 'SELECT 1'" 2>&1)"
check "mariadb-dump from a server without TLS" yes "$(docker exec $WP sh -c "MYSQL_PWD=r mariadb-dump -h $DBOLD -uroot mysql" 2>/dev/null | grep -q 'CREATE TABLE' && echo yes || echo no)"
docker rm -fv $DBOLD >/dev/null

docker exec $WP sh -c 'mkdir -p wp-content/uploads/2026/10 && P="<?php echo \"PHP-EXECUTED\";" && echo "$P" > wp-content/uploads/2026/10/evil.php && echo "$P" > wp-content/uploads/2026/10/evil.PHtml && echo "$P" > wp-content/uploads/2026/10/evil.phar && echo secret > wp-content/debug.log && echo x > wp-config.php.bak && echo x > dump.sql && mkdir -p .git && echo "[core]" > .git/config && echo X=1 > .env && mkdir -p .well-known && echo ok > .well-known/test.txt'
check "uploads: evil.php blocked" 404 "$(code /wp-content/uploads/2026/10/evil.php)"
check "uploads: path-info evil.php/x.jpg blocked" 404 "$(code /wp-content/uploads/2026/10/evil.php/x.jpg)"
check "uploads: evil.PHtml blocked" 404 "$(code /wp-content/uploads/2026/10/evil.PHtml)"
check "uploads: evil.phar blocked" 404 "$(code /wp-content/uploads/2026/10/evil.phar)"
check "debug.log blocked" 404 "$(code /wp-content/debug.log)"
check "wp-config.php.bak blocked" 404 "$(code /wp-config.php.bak)"
check "dump.sql blocked" 404 "$(code /dump.sql)"
check ".git/config blocked" 404 "$(code /.git/config)"
check ".env blocked" 404 "$(code /.env)"
check ".well-known still served" 200 "$(code /.well-known/test.txt)"
check "plugin php still runs (akismet index)" 200 "$(code /wp-content/plugins/index.php)"

hdr=$(curl -sI $B/)
check "X-Content-Type-Options" nosniff "$(grep -i '^x-content-type-options' <<<"$hdr" | awk '{print $2}' | tr -d '\r')"
check "Referrer-Policy" strict-origin-when-cross-origin "$(grep -i '^referrer-policy' <<<"$hdr" | awk '{print $2}' | tr -d '\r')"
check "X-Frame-Options" SAMEORIGIN "$(grep -i '^x-frame-options' <<<"$hdr" | awk '{print $2}' | tr -d '\r')"
check "single X-Frame-Options on wp-login" 1 "$(curl -sI $B/wp-login.php | grep -ci '^x-frame-options')"
check "static Cache-Control" "public, max-age=2592000" "$(curl -sI $B/wp-includes/css/dashicons.min.css | grep -i '^cache-control' | cut -d' ' -f2- | tr -d '\r')"
check "page has no long cache" 0 "$(grep -ci 'max-age=2592000' <<<"$hdr")"
# Requests reach the container from the Docker bridge, a private range, so
# they count as coming from a trusted proxy.
docker exec $WP sh -c 'echo "<?php echo \$_SERVER[\"REMOTE_ADDR\"];" > ip.php'
check "REMOTE_ADDR from X-Forwarded-For (trusted proxy)" 203.0.113.7 "$(curl -s -H 'X-Forwarded-For: 203.0.113.7' $B/ip.php)"
check "REMOTE_ADDR without proxy header is the peer" no "$(curl -s $B/ip.php | grep -q '^203\.0\.113\.7$' && echo yes || echo no)"
docker exec $WP sh -c 'echo "<?php require __DIR__ . \"/wp-load.php\"; echo is_ssl() ? \"https\" : \"http\";" > ssl.php'
check "HTTPS via X-Forwarded-Proto from trusted proxy" https "$(curl -s -H 'X-Forwarded-Proto: https' $B/ssl.php)"
check "HTTPS via CloudFront-Forwarded-Proto" https "$(curl -s -H 'CloudFront-Forwarded-Proto: https' $B/ssl.php)"
check "plain HTTP stays HTTP" http "$(curl -s $B/ssl.php)"
check "forged internal HTTPS marker ignored" http "$(curl -s -H 'X-Frankenpress-Https: on' $B/ssl.php)"
check "forged marker with underscores ignored" http "$(curl -s -H 'X_Frankenpress_Https: on' $B/ssl.php)"
check "headers can't forge the trust signal" http "$(curl -s -H 'Frankenpress-Https: on' -H 'Frankenpress-Trusted-Proxy: true' $B/ssl.php)"
check "xmlrpc.php allowed by default" 405 "$(code /xmlrpc.php)"
check "wp-cli works from any directory" yes "$(docker exec -w / $WP wp core version >/dev/null 2>&1 && echo yes || echo no)"
check "healthcheck endpoint" ok "$(docker exec $WP curl -fsS http://127.0.0.1:2080/healthz.php 2>/dev/null)"
for _ in $(seq 1 20); do st=$(docker inspect $WP --format '{{.State.Health.Status}}'); [ "$st" != starting ] && break; sleep 3; done
check "docker health status" healthy "$st"
# REST API under /wp-json/ with plain permalinks (the fresh install default)
docker exec $WP wp rewrite structure '' >/dev/null 2>&1
check "/wp-json/ is the REST index (plain permalinks)" yes "$(curl -s $B/wp-json/ | grep -q '"namespaces"' && echo yes || echo no)"
check "/wp-json/wp/v2/posts?per_page=1 returns one post" 1 "$(curl -s "$B/wp-json/wp/v2/posts?per_page=1" | jq length 2>/dev/null)"
check "POST /wp-json/ keeps method (401 unauthenticated)" 401 "$(curl -s -o /dev/null -w '%{http_code}' -X POST -d 'title=x' $B/wp-json/wp/v2/posts)"
docker exec $WP wp rewrite structure '/%postname%/' >/dev/null 2>&1
check "/wp-json/ with pretty permalinks" yes "$(curl -s $B/wp-json/ | grep -q '"namespaces"' && echo yes || echo no)"

# DISALLOW_FILE_EDIT: on by default; $WP2 defines it false itself, $WP3 sets
# DISALLOW_FILE_EDIT=0 (both below)
dfe='echo var_export(defined("DISALLOW_FILE_EDIT") ? DISALLOW_FILE_EDIT : "undefined", true);'
docker exec $WP sh -c "echo '<?php require __DIR__ . \"/wp-load.php\"; $dfe' > dfe.php"
check "DISALLOW_FILE_EDIT on by default (web)" true "$(curl -s $B/dfe.php)"
check "DISALLOW_FILE_EDIT on by default (wp-cli)" true "$(docker exec $WP wp eval "$dfe" 2>/dev/null)"
check "plugin editor refused by default" no "$(docker exec $WP wp eval 'wp_set_current_user(1); echo current_user_can("edit_plugins") ? "yes" : "no";' 2>/dev/null)"
# DISALLOW_PLUGIN_THEME_INSTALL and DISABLE_APPLICATION_PASSWORDS: on by
# default, =0 turns them off ($WP3 below). Capabilities as admin user 1;
# application passwords need HTTPS, so ask through a trusted proxy.
caps='wp_set_current_user(1); foreach (["install_plugins","upload_plugins","install_themes","upload_themes","update_plugins","activate_plugins","delete_plugins"] as $c) echo current_user_can($c) ? 1 : 0;'
apw='echo wp_is_application_passwords_supported() ? "s" : "-", wp_is_application_passwords_available() ? "a" : "-";'
docker exec $WP sh -c "echo '<?php require __DIR__ . \"/wp-load.php\"; $caps' > caps.php; echo '<?php require __DIR__ . \"/wp-load.php\"; $apw' > apw.php"
check "plugin/theme install+upload refused, update/activate/delete allowed (web)" 0000111 "$(curl -s $B/caps.php)"
check "plugin/theme install+upload refused, update/activate/delete allowed (wp-cli)" 0000111 "$(docker exec $WP wp eval "$caps" 2>/dev/null)"
check "application passwords off by default (HTTPS supported, not available)" s- "$(curl -s -H 'X-Forwarded-Proto: https' $B/apw.php)"
# CORE_UPGRADE_SKIP_NEW_BUNDLED: on by default, a site's own define in
# WORDPRESS_CONFIG_EXTRA wins without "Constant already defined" warnings,
# and CORE_UPGRADE_SKIP_NEW_BUNDLED=0 without a define leaves it undefined
skip_bundled='echo defined("CORE_UPGRADE_SKIP_NEW_BUNDLED") ? var_export(CORE_UPGRADE_SKIP_NEW_BUNDLED, true) : "undefined";'
docker exec $WP sh -c "echo '<?php require __DIR__ . \"/wp-load.php\"; $skip_bundled' > skip.php"
check "CORE_UPGRADE_SKIP_NEW_BUNDLED on by default (web)" true "$(curl -s $B/skip.php)"
check "CORE_UPGRADE_SKIP_NEW_BUNDLED on by default (wp-cli)" true "$(docker exec $WP wp eval "$skip_bundled" 2>/dev/null)"
docker run -d --name $WP2 --network $NET -e WORDPRESS_DB_HOST=$DB -e WORDPRESS_DB_USER=wp -e WORDPRESS_DB_PASSWORD=wp -e WORDPRESS_DB_NAME=wp -e "WORDPRESS_CONFIG_EXTRA=define('CORE_UPGRADE_SKIP_NEW_BUNDLED', false); define('DISALLOW_FILE_EDIT', false);" "$IMG" >/dev/null
docker run -d --name $WP3 --network $NET -e WORDPRESS_DB_HOST=$DB -e WORDPRESS_DB_USER=wp -e WORDPRESS_DB_PASSWORD=wp -e WORDPRESS_DB_NAME=wp -e CORE_UPGRADE_SKIP_NEW_BUNDLED=0 -e DISALLOW_FILE_EDIT=0 -e DISALLOW_PLUGIN_THEME_INSTALL=0 -e DISABLE_APPLICATION_PASSWORDS=0 "$IMG" >/dev/null
for c in $WP2 $WP3; do
  for _ in $(seq 1 30); do docker exec $c curl -s -o /dev/null http://127.0.0.1/healthz 2>/dev/null && break; sleep 1; done
done
docker exec $WP2 sh -c "echo '<?php require __DIR__ . \"/wp-load.php\"; $skip_bundled' > skip.php"
check "site's own define in WORDPRESS_CONFIG_EXTRA wins (web)" false "$(docker exec $WP2 curl -s http://127.0.0.1/skip.php)"
check "site's own define in WORDPRESS_CONFIG_EXTRA wins (wp-cli)" false "$(docker exec $WP2 wp eval "$skip_bundled" 2>/dev/null)"
docker exec $WP2 sh -c "echo '<?php require __DIR__ . \"/wp-load.php\"; $dfe' > dfe.php"
check "site's own DISALLOW_FILE_EDIT define wins (web)" false "$(docker exec $WP2 curl -s http://127.0.0.1/dfe.php)"
check "no 'already defined' warning for the site's own define" 0 "$(docker logs $WP2 2>&1 | grep -ci 'already defined')"
docker exec $WP3 sh -c "echo '<?php require __DIR__ . \"/wp-load.php\"; $skip_bundled' > skip.php"
check "CORE_UPGRADE_SKIP_NEW_BUNDLED=0 turns it off (web)" undefined "$(docker exec $WP3 curl -s http://127.0.0.1/skip.php)"
check "CORE_UPGRADE_SKIP_NEW_BUNDLED=0 turns it off (wp-cli)" undefined "$(docker exec $WP3 wp eval "$skip_bundled" 2>/dev/null)"
docker exec $WP3 sh -c "echo '<?php require __DIR__ . \"/wp-load.php\"; $dfe' > dfe.php"
check "DISALLOW_FILE_EDIT=0 turns it off (web)" "'undefined'" "$(docker exec $WP3 curl -s http://127.0.0.1/dfe.php)"
check "DISALLOW_FILE_EDIT=0 turns it off (wp-cli)" "'undefined'" "$(docker exec $WP3 wp eval "$dfe" 2>/dev/null)"
docker exec $WP3 sh -c "echo '<?php require __DIR__ . \"/wp-load.php\"; $caps' > caps.php; echo '<?php require __DIR__ . \"/wp-load.php\"; $apw' > apw.php"
check "DISALLOW_PLUGIN_THEME_INSTALL=0 allows installs again" 1111111 "$(docker exec $WP3 curl -s http://127.0.0.1/caps.php)"
check "DISABLE_APPLICATION_PASSWORDS=0 brings them back" sa "$(docker exec $WP3 curl -s -H 'X-Forwarded-Proto: https' http://127.0.0.1/apw.php)"
docker rm -fv $WP3 >/dev/null

# UMASK: $WP runs with UMASK=0002, $WP2 without
umask_probe='<?php file_put_contents(__DIR__ . "/umask-web.txt", "x"); echo substr(sprintf("%o", fileperms(__DIR__ . "/umask-web.txt")), -3);'
for c in $WP $WP2; do docker exec $c sh -c "rm -f umask-*.txt; echo '$umask_probe' > umask.php"; done
check "UMASK=0002: file written in a web request is 664" 664 "$(curl -s $B/umask.php)"
check "UMASK=0002: file written by docker exec wp is 664" 664 "$(docker exec $WP wp eval 'touch(ABSPATH . "umask-cli.txt"); echo substr(sprintf("%o", fileperms(ABSPATH . "umask-cli.txt")), -3);' 2>/dev/null)"
check "UMASK=0002: plugin/theme updates use 664/775" 664/775 "$(docker exec $WP wp eval 'require_once ABSPATH . "wp-admin/includes/file.php"; WP_Filesystem(); printf("%o/%o", FS_CHMOD_FILE, FS_CHMOD_DIR & 0777);' 2>/dev/null)"
check "without UMASK: file written in a web request is 644" 644 "$(docker exec $WP2 curl -s http://127.0.0.1/umask.php)"
check "without UMASK: file written by docker exec wp is 644" 644 "$(docker exec $WP2 wp eval 'touch(ABSPATH . "umask-cli.txt"); echo substr(sprintf("%o", fileperms(ABSPATH . "umask-cli.txt")), -3);' 2>/dev/null)"
# $WP2 runs without SUPERCACHE: the same kind of file is left to WordPress,
# which redirects 127.0.0.1 to the site URL
check "supercache: off without SUPERCACHE=1" "301 " "$(docker exec $WP2 sh -c 'mkdir -p wp-content/cache/supercache/127.0.0.1/sc-test && echo x > wp-content/cache/supercache/127.0.0.1/sc-test/index.html && curl -s -o /dev/null -w "%{http_code} %header{x-frankenpress-cache}" http://127.0.0.1/sc-test/')"
docker rm -fv $WP2 >/dev/null

check "HSTS not sent over plain HTTP" 0 "$(curl -sI $B/ | grep -ci '^strict-transport-security:')"
check "HSTS sent when proxy forwards HTTPS" "max-age=300" "$(curl -sI -H 'X-Forwarded-Proto: https' $B/ | grep -i '^strict-transport-security:' | cut -d' ' -f2- | tr -d '\r')"
check "brotli" br "$(curl -s -H 'Accept-Encoding: br' -o /dev/null -w '%header{content-encoding}' $B/)"

# SUPERCACHE=1 ($WP): WP Super Cache's files are served without PHP, the
# plugin's bypass conditions fall through to WordPress. Files written by hand
# in the plugin's layout (wp-content/cache/supercache/<host><path>index.html).
docker exec $WP sh -c 'd=wp-content/cache/supercache/localhost/sc-test; mkdir -p $d && echo cached-http > $d/index.html && echo cached-https > $d/index-https.html && echo cached-gzip | gzip > $d/index.html.gz'
sc() { curl -s -o /dev/null -w '%{http_code} %header{x-frankenpress-cache}' "$@"; } # "200 HIT" from the cache, "404 " from WordPress
check "supercache: cached page served without PHP" "200 HIT cached-http" "$(sc $B/sc-test/) $(curl -s -H 'Accept-Encoding: identity' $B/sc-test/)"
check "supercache: HTTPS via trusted proxy gets index-https.html" cached-https "$(curl -s -H 'X-Forwarded-Proto: https' -H 'Accept-Encoding: identity' $B/sc-test/)"
check "supercache: precompressed index.html.gz" "gzip cached-gzip" "$(curl -s -o /dev/null -w '%header{content-encoding}' -H 'Accept-Encoding: gzip' $B/sc-test/) $(curl -s -H 'Accept-Encoding: gzip' $B/sc-test/ | gunzip)"
check "supercache: Cache-Control as the plugin sends it" "max-age=3, must-revalidate" "$(curl -s -o /dev/null -w '%header{cache-control}' $B/sc-test/)"
check "supercache: bypassed for logged-in users" "404 " "$(sc -H 'Cookie: a=1; wordpress_logged_in_x=y' $B/sc-test/)"
check "supercache: bypassed for comment authors" "404 " "$(sc -H 'Cookie: comment_author_x=y' $B/sc-test/)"
check "supercache: bypassed with a query string" "404 " "$(sc "$B/sc-test/?sc=1")"
check "supercache: bypassed for POST" "404 " "$(sc -X POST $B/sc-test/)"
check "supercache: path without trailing slash not served" "404 " "$(sc $B/sc-test)"

# --- image processing through WordPress
docker exec -i $WP sh -c 'cat > /tmp/img.php' <<'EOF'
<?php
$jpg = "/tmp/t.jpg"; $i = imagecreatetruecolor(1600, 1200); imagejpeg($i, $jpg);
$pdf = "/tmp/t.pdf";
file_put_contents($pdf, "%PDF-1.4\n1 0 obj<</Type/Catalog/Pages 2 0 R>>endobj 2 0 obj<</Type/Pages/Kids[3 0 R]/Count 1>>endobj 3 0 obj<</Type/Page/Parent 2 0 R/MediaBox[0 0 200 200]>>endobj\ntrailer<</Root 1 0 R>>\n%%EOF");
$ps = "/tmp/t.ps"; file_put_contents($ps, "%!PS\n/Helvetica findfont 12 scalefont setfont 10 10 moveto (x) show showpage\n");
$svg = "/tmp/t.svg"; file_put_contents($svg, '<svg xmlns="http://www.w3.org/2000/svg" width="10" height="10"/>');
function try_read($f) { try { $im = new Imagick($f); return "read"; } catch (Throwable $e) { return "blocked"; } }
echo "imagick_pdf=", try_read($pdf."[0]"), "\n";
echo "imagick_ps=", try_read($ps), "\n";
echo "imagick_svg=", try_read($svg), "\n";
foreach (["WEBP","AVIF"] as $f) { try { $x = new Imagick(); $x->newImage(8,8,"red"); $x->setImageFormat($f); $x->getImageBlob(); echo strtolower($f), "_write=ok\n"; } catch (Throwable $e) { echo strtolower($f), "_write=blocked\n"; } }
EOF
res=$(docker exec $WP php /tmp/img.php 2>&1)
v() { grep "^$1=" <<<"$res" | cut -d= -f2; }
check "Imagick reads PDF (thumbnails)" read "$(v imagick_pdf)"
check "Imagick refuses PostScript" blocked "$(v imagick_ps)"
check "Imagick refuses SVG" blocked "$(v imagick_svg)"
check "Imagick writes WebP" ok "$(v webp_write)"
check "Imagick writes AVIF" ok "$(v avif_write)"

[ "$VARIANT" = vips-ffi ] && docker exec $WP wp plugin activate vips-image-editor-ffi >/dev/null 2>&1
up=$(docker exec $WP sh -c 'id=$(wp media import /tmp/t.jpg --porcelain) && wp post meta get "$id" _wp_attachment_metadata --format=json | php -r "echo count(json_decode(stream_get_contents(STDIN),true)[\"sizes\"]);"' 2>/dev/null)
check "JPEG upload generates 5 sizes" 5 "$up"
pdfthumb=$(docker exec $WP sh -c 'id=$(wp media import /tmp/t.pdf --porcelain) && wp post meta get "$id" _wp_attachment_metadata --format=json | php -r "\$m=json_decode(stream_get_contents(STDIN),true); echo isset(\$m[\"sizes\"][\"full\"]) ? \"yes\" : \"no\";"' 2>/dev/null)
check "PDF upload gets a thumbnail" yes "$pdfthumb"
if [ "$VARIANT" = vips-ffi ]; then
  check "VIPS editor in use" 'NotGlossy\VipsImageEditorFFI\Image_Editor_Vips_FFI' "$(docker exec $WP wp eval 'echo get_class(wp_get_image_editor("/tmp/t.jpg"));' 2>/dev/null)"
fi

# Mail: PHP's mail() during a web request goes through sendmail -> msmtp
docker exec $WP sh -c 'echo "<?php var_export(mail(\"alice@example.org\", \"FrankenPress test\", \"Hello\", \"From: WordPress <wordpress@site.example>\"));" > mail.php'
check "mail() from a web request succeeds" true "$(curl -s $B/mail.php)"
sleep 1
check "message delivered via MSMTP_* relay" "FrankenPress test alice@example.org noreply@site.example" "$(m=$(curl -s "http://localhost:$((PORT + 2))/api/v1/messages") && id=$(jq -r '.messages[0].ID' <<<"$m") && echo "$(jq -r '.messages[0] | "\(.Subject) \(.To[0].Address)"' <<<"$m") $(curl -s "http://localhost:$((PORT + 2))/api/v1/message/$id/headers" | jq -r '."Return-Path"[0]' | tr -d '<>')")"
# wp_mail() as WordPress itself sends; the test site's URL is localhost, so
# give WordPress a From address with a real domain
check "wp_mail() succeeds" true "$(docker exec $WP wp eval 'add_filter("wp_mail_from", fn() => "wordpress@site.example"); var_export(wp_mail("bob@example.org", "wp_mail test", "Hello"));' 2>/dev/null)"
sleep 1
check "wp_mail() arrives with the configured sender" "bob@example.org noreply@site.example" "$(m=$(curl -s "http://localhost:$((PORT + 2))/api/v1/search?query=subject:%22wp_mail%20test%22") && id=$(jq -r '.messages[0].ID' <<<"$m") && echo "$(jq -r '.messages[0].To[0].Address' <<<"$m") $(curl -s "http://localhost:$((PORT + 2))/api/v1/message/$id/headers" | jq -r '."Return-Path"[0]' | tr -d '<>')")"
check "startup log shows the umask" 1 "$(docker logs $WP 2>&1 | grep -c 'FrankenPress: umask 0002')"
check "startup log names the mail relay" 1 "$(docker logs $WP 2>&1 | grep -c "FrankenPress: mail is sent via $MAIL:1025")"
check "msmtp logs the delivery to the container log" 1 "$(docker logs $WP 2>&1 | grep -c 'MSMTP .*recipients=alice@example.org.*exitcode=EX_OK')"

# Request size cap and header timeout, on small limits so the test is quick
LIM=fplim-$$
docker run -d --name $LIM -p $((PORT + 1)):80 -e REQUEST_BODY_MAX_BYTES=1024 -e TIMEOUT_READ_HEADER=2s -e TRUSTED_PROXIES=198.51.100.0/24 --entrypoint sh "$IMG" -c 'echo "<?php echo \$_SERVER[\"HTTP_X_FORWARDED_PROTO\"] ?? \"none\", \" \", (empty(\$_SERVER[\"HTTPS\"]) ? \"off\" : \$_SERVER[\"HTTPS\"]);" > /var/www/html/proto.php && echo "<?php var_export(mail(\"a@example.org\", \"t\", \"b\"));" > /var/www/html/mail.php && exec frankenpress-entrypoint.sh frankenphp run --config /etc/caddy/Caddyfile' >/dev/null
for _ in $(seq 1 30); do curl -s -o /dev/null "http://localhost:$((PORT + 1))/healthz" && break; sleep 1; done
check "body over REQUEST_BODY_MAX_BYTES refused (413)" 413 "$(head -c 4096 /dev/zero | curl -s -o /dev/null -w '%{http_code}' --data-binary @- "http://localhost:$((PORT + 1))/index.php")"
check "body under the limit still accepted" 200 "$(head -c 512 /dev/zero | curl -s -o /dev/null -w '%{http_code}' --data-binary @- "http://localhost:$((PORT + 1))/healthz")"
slow=$(python3 - "$((PORT + 1))" <<'PY'
import socket, sys, time
s = socket.create_connection(("localhost", int(sys.argv[1])))
s.sendall(b"GET / HTTP/1.1\r\nHost: x\r\n")  # never finish the headers
start = time.time()
s.settimeout(15)
try:
    while s.recv(1024):
        pass
except Exception:
    pass
print("closed" if time.time() - start < 10 else "open")
PY
)
check "stalled request headers time out (TIMEOUT_READ_HEADER)" closed "$slow"
check "X-Forwarded-Proto from untrusted client dropped" "none off" "$(curl -s -H 'X-Forwarded-Proto: https' "http://localhost:$((PORT + 1))/proto.php")"
check "X_Forwarded_Proto (underscore) from untrusted client dropped" "none off" "$(curl -s -H 'X_Forwarded_Proto: https' "http://localhost:$((PORT + 1))/proto.php")"
check "X-Forwarded_Proto (mixed) from untrusted client dropped" "none off" "$(curl -s -H 'X-Forwarded_Proto: https' "http://localhost:$((PORT + 1))/proto.php")"
# Unconfigured mail is visible: once at startup, and for every failed mail
check "startup log says mail isn't configured" 1 "$(docker logs $LIM 2>&1 | grep -c 'FrankenPress: mail is NOT configured')"
check "mail() without a relay fails in a web request" false "$(curl -s "http://localhost:$((PORT + 1))/mail.php")"
check "the failed mail is logged" 1 "$(docker logs $LIM 2>&1 | grep -c 'sendmail: no SMTP relay configured')"
docker rm -fv $LIM >/dev/null
check "invalid UMASK stops the container with a message" "FrankenPress: invalid UMASK 'abc'" "$(docker run --rm -e UMASK=abc "$IMG" 2>&1 | grep -o "FrankenPress: invalid UMASK 'abc'")"

errs=$(docker logs $WP 2>&1 | grep -E '"level":"error"|PHP (Fatal|Warning|Parse)' | grep -v 'install root certificate' | head -3)
check "no errors in container log" "" "$errs"
[ $fail = 0 ] && echo "ALL CHECKS PASSED" || echo "SOME CHECKS FAILED"
exit $fail
