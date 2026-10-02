#!/usr/bin/env bash
# Integration test for a built FrankenPress image.
#
# Usage: tests/integration.sh <image> <standard|vips-ffi>
#
# Starts MariaDB and the image, installs WordPress, then checks runtime health,
# the hardening rules, proxy handling and image processing. Needs Docker and
# curl, jq and python3; exits non-zero if any check fails.
set -u
IMG=$1; VARIANT=$2; NET=fpt-$$; WP=fpwp-$$; DB=fpdb-$$; PORT=${PORT:-18081}
fail=0
check() { # check <description> <expected> <actual>
  if [ "$2" = "$3" ]; then printf "  ok    %-52s %s\n" "$1" "$3"; else printf "  FAIL  %-52s expected=%s got=%s\n" "$1" "$2" "$3"; fail=1; fi
}
cleanup() { docker rm -fv $WP $DB >/dev/null 2>&1; docker network rm $NET >/dev/null 2>&1; }
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
check "wp-cli works" yes "$(docker run --rm "$IMG" wp --version 2>/dev/null | grep -q '^WP-CLI [0-9]' && echo yes || echo no)"
check "opcache.max_accelerated_files" 20000 "$(docker run --rm "$IMG" php -r 'echo ini_get("opcache.max_accelerated_files");')"
check "memory_limit" 256M "$(docker run --rm "$IMG" php -r 'echo ini_get("memory_limit");')"
check "real hostname uses ACME, not internal CA" "" "$(docker run --rm -e SERVER_NAME=example.com --entrypoint frankenphp "$IMG" adapt --config /etc/caddy/Caddyfile 2>/dev/null | grep -o '"module":"internal"')"
check "max_input_vars" 5000 "$(docker run --rm "$IMG" php -r 'echo ini_get("max_input_vars");')"

# FIX_PERMISSIONS: a root-owned volume (with a symlink planted in it) gets
# repaired at startup, then the process drops to www-data
VOL=fpvol-$$
docker volume create $VOL >/dev/null
docker run --rm -v $VOL:/data/caddy --entrypoint sh "$IMG" -c 'exit 0' >/dev/null 2>&1
docker run --rm --user root -v $VOL:/data/caddy --entrypoint sh "$IMG" -c 'mkdir -p /data/caddy/certs && touch /data/caddy/certs/x && ln -s /etc/shadow /data/caddy/link && chown -R root:root /data/caddy'
fix=$(docker run --rm --user root -e FIX_PERMISSIONS=1 -v $VOL:/data/caddy "$IMG" sh -c 'echo "$(id -un) $(stat -c %U /data/caddy/certs/x) $(stat -L -c %U /etc/shadow)"' 2>/dev/null | tail -1)
check "FIX_PERMISSIONS repairs ownership, drops to www-data" "www-data www-data root" "$fix"
docker volume rm $VOL >/dev/null

# --- runtime
docker network create $NET >/dev/null
docker run -d --name $DB --network $NET -e MARIADB_ROOT_PASSWORD=r -e MARIADB_DATABASE=wp -e MARIADB_USER=wp -e MARIADB_PASSWORD=wp mariadb:11 >/dev/null
for _ in $(seq 1 40); do docker exec $DB mariadb -uwp -pwp -e 'select 1' wp >/dev/null 2>&1 && break; sleep 2; done
docker run -d --name $WP --network $NET -p $PORT:80 -e DISALLOW_FILE_EDIT=1 -e HSTS=max-age=300 -e WORDPRESS_DB_HOST=$DB -e WORDPRESS_DB_USER=wp -e WORDPRESS_DB_PASSWORD=wp -e WORDPRESS_DB_NAME=wp "$IMG" >/dev/null
for _ in $(seq 1 30); do curl -s -o /dev/null http://localhost:$PORT/ && break; sleep 1; done
docker exec $WP wp core install --url=http://localhost:$PORT --title=T --admin_user=a --admin_password=a --admin_email=a@example.com --skip-email >/dev/null 2>&1
B=http://localhost:$PORT
code() { curl -s -o /dev/null -w '%{http_code}' "$B$1"; }
check "home page (default SERVER_NAME :80)" 200 "$(code /)"
check "public /healthz without PHP" ok "$(curl -s $B/healthz)"
check "Server header hidden" 0 "$(curl -sI $B/ | grep -ci '^server:')"
check "wp-login.php" 200 "$(code /wp-login.php)"
check "wp-admin css (static)" 200 "$(code /wp-admin/css/login.min.css)"

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

docker exec $WP sh -c 'echo "<?php require __DIR__ . \"/wp-load.php\"; echo (defined(\"DISALLOW_FILE_EDIT\") && DISALLOW_FILE_EDIT) ? \"on\" : \"off\";" > dfe.php'
check "DISALLOW_FILE_EDIT=1 applied" on "$(curl -s $B/dfe.php)"
check "HSTS not sent over plain HTTP" 0 "$(curl -sI $B/ | grep -ci '^strict-transport-security:')"
check "HSTS sent when proxy forwards HTTPS" "max-age=300" "$(curl -sI -H 'X-Forwarded-Proto: https' $B/ | grep -i '^strict-transport-security:' | cut -d' ' -f2- | tr -d '\r')"
check "brotli" br "$(curl -s -H 'Accept-Encoding: br' -o /dev/null -w '%header{content-encoding}' $B/)"

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

# Request size cap and header timeout, on small limits so the test is quick
LIM=fplim-$$
docker run -d --name $LIM -p $((PORT + 1)):80 -e REQUEST_BODY_MAX_BYTES=1024 -e TIMEOUT_READ_HEADER=2s -e TRUSTED_PROXIES=198.51.100.0/24 --entrypoint sh "$IMG" -c 'echo "<?php echo \$_SERVER[\"HTTP_X_FORWARDED_PROTO\"] ?? \"none\", \" \", (empty(\$_SERVER[\"HTTPS\"]) ? \"off\" : \$_SERVER[\"HTTPS\"]);" > /var/www/html/proto.php && exec frankenphp run --config /etc/caddy/Caddyfile' >/dev/null
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
docker rm -fv $LIM >/dev/null

errs=$(docker logs $WP 2>&1 | grep -E '"level":"error"|PHP (Fatal|Warning|Parse)' | grep -v 'install root certificate' | head -3)
check "no errors in container log" "" "$errs"
[ $fail = 0 ] && echo "ALL CHECKS PASSED" || echo "SOME CHECKS FAILED"
exit $fail
