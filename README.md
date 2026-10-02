# FrankenPress Docker Image

A WordPress image built for simplicity and scale, powered by FrankenPHP and Caddy.

## Quick Start

```bash
docker run -d \
  -p 80:80 \
  -e WORDPRESS_DB_HOST=your-db-host \
  -e WORDPRESS_DB_USER=wordpress \
  -e WORDPRESS_DB_PASSWORD=your-password \
  -e WORDPRESS_DB_NAME=wordpress \
  bock/frankenpress:latest
```

For a complete setup with MariaDB, a Redis object cache and an optional phpMyAdmin, see [`examples/compose`](examples/compose/compose.yaml):

```bash
cd examples/compose
cp .env.example .env   # set SERVER_NAME and the passwords
docker compose up -d
```

## Available Images

### Standard Images
- `bock/frankenpress:latest` / `trixie` - Latest (PHP 8.5) on Debian Trixie (amd64, arm64)
- `bock/frankenpress:php-8.5-trixie` - PHP 8.5 on Debian Trixie (amd64, arm64)

### VIPS Images (with FFI support for advanced image processing)
- `bock/frankenpress:vips-ffi` / `vips-ffi-trixie` - Latest VIPS (PHP 8.5) on Debian Trixie (amd64, arm64)
- `bock/frankenpress:php-8.5-vips-ffi-trixie` - PHP 8.5 VIPS on Debian Trixie (amd64, arm64)

All images are built on Debian 13 (Trixie) with PHP 8.5. Both variants come from the same `Dockerfile`: the VIPS image is its `vips-ffi` target (`docker build --target vips-ffi .`).

### Pinning a Version
The tags above follow the weekly rebuilds. To pin a deployment, or roll back after an update, use the version-specific tags published with every build:
- `bock/frankenpress:php-8.5-trixie-wp7.1.2`: a specific WordPress version, still updated by the weekly rebuilds of that version
- `bock/frankenpress:php-8.5-trixie-wp7.1.2-20261004`: one specific build (WordPress version plus build date)

The same pattern applies to the VIPS images, e.g. `php-8.5-vips-ffi-trixie-wp7.1.2-20261004`. See the [tag list on Docker Hub](https://hub.docker.com/r/bock/frankenpress/tags) for available builds.

## Performance & Build Optimization

All arm64 builds run on native GitHub-hosted ARM runners (`ubuntu-24.04-arm`) for maximum performance and speed. This eliminates QEMU emulation overhead, resulting in significantly faster build times.

The PHP extensions are compiled in a separate build stage on the official [FrankenPHP image](https://hub.docker.com/r/dunglas/frankenphp). The published image is Debian slim plus PHP, FrankenPHP and only the libraries they link against, with no compiler toolchain. That puts the standard image at about 585 MB and the VIPS image at about 650 MB.

The base images (`wordpress`, `dunglas/frankenphp`, `debian`) are pinned by digest in the `Dockerfile`, so every build uses exactly the images recorded in git. Dependabot opens a pull request when one of them changes, and CI runs the full integration test on it before it's merged. Debian package updates in the final image still arrive with every weekly rebuild.

## Links

- [Docker Hub](https://hub.docker.com/r/bock/frankenpress)
- [GitHub Repository](https://github.com/bb/frankenpress)

## What's Included

### Core Components

- **[WordPress](https://wordpress.org/)** - Latest version from official WordPress Docker images
- **[FrankenPHP](https://frankenphp.dev/)** - Modern PHP application server (official [dunglas/frankenphp](https://hub.docker.com/r/dunglas/frankenphp) images)
- **[Caddy](https://caddyserver.com/)** - Fast, secure web server with automatic HTTPS
- **PHP Extensions** - Optimized selection for WordPress performance

There is no built-in page cache. Use a caching plugin, and Redis for the object cache, as in the [compose example](examples/compose/compose.yaml). Variables such as `CACHE_LOC`, `TTL`, `PURGE_*`, `BYPASS_*` or `CACHE_RESPONSE_CODES` from older FrankenWP examples have no effect.

### PHP Extensions & Caching

**Performance & Caching:**
- OPcache (built into PHP 8.5, configured for production)
- APCu
- Memcached
- Redis
- igbinary
- msgpack

**WordPress Essentials:**
- bcmath
- exif
- gd
- intl
- mysqli
- zip
- imagick

**VIPS Images Only:**
- FFI (Foreign Function Interface)
- libvips (high-performance image processing)

### Environment Variables

#### FrankenPHP

- `SERVER_NAME`: the addresses to listen on. Defaults to `:80`: plain HTTP for any hostname, which is what a container behind a load balancer or reverse proxy needs. For HTTPS, set your hostname(s), e.g. `example.com` or `example.com, :80`; real hostnames get a publicly trusted certificate (Let's Encrypt/ZeroSSL) automatically, `localhost` and IP addresses use Caddy's local CA
- `TIMEOUT_READ_HEADER`, `TIMEOUT_READ_BODY`, `TIMEOUT_WRITE`, `TIMEOUT_IDLE`: how long a client may take to send its headers (default `10s`) and body (`10m`), how long PHP plus sending the response may take (`10m`), and how long idle keep-alive connections stay open (`5m`). Bounds slow or stalled clients, which would otherwise hold PHP threads
- `REQUEST_BODY_MAX_BYTES`: requests announcing a larger body get 413 before PHP starts on them. Defaults to `536870912` (512 MiB, matching `upload_max_filesize`/`post_max_size`); raise it together with those PHP settings
- `CADDY_GLOBAL_OPTIONS`: inserted into Caddy's global options block, e.g. `email admin@example.com` for the Let's Encrypt account or `debug`
- `CADDY_SERVER_EXTRA_DIRECTIVES`: inserted into the site block, before WordPress handles the request, e.g. `header /wp-content/uploads/* Cache-Control "public, max-age=31536000, immutable"`
- `CADDY_EXTRA_CONFIG`: inserted at the top level of the Caddyfile, e.g. an extra site block. See [Custom Caddy Configuration](#custom-caddy-configuration)
- `FRANKENPHP_CONFIG`: inject config under the frankenphp directive, e.g. `num_threads` and `max_threads`. See [Resource Limits](#resource-limits)
- `TRUSTED_PROXIES`: proxies whose `X-Forwarded-For` header is trusted for the client IP, as space-separated CIDRs. Defaults to `private_ranges` (10/8, 172.16/12, 192.168/16, 127/8 and their IPv6 equivalents). Set it to your load balancer's range so other hosts on a private network can't spoof their IP. Trusted proxies can also mark a request as HTTPS via `X-Forwarded-Proto` or `CloudFront-Forwarded-Proto`
- `FIX_OWNERSHIP`: set to `1` and start the container as root (`--user root`, or `user: root` in compose) to repair ownership of mounted folders at startup. Useful when bind mounts or platforms like AWS ECS hand the container root-owned folders, so uploads or certificates can't be written. Files not owned by the web user in `/var/www/html`, `/data/caddy` and `/config/caddy` are chowned (symlinks themselves, never their targets), then the server drops to `www-data`. Without `FIX_OWNERSHIP`, the image runs as `www-data` as before. Images from 2026-10-02 called it `FIX_PERMISSIONS`; that name now stops the container with a message
- `UMASK`: file creation mask, e.g. `0002` for group-writable files. Unset keeps `0022`. See [Sharing wp-content with another user](#sharing-wp-content-with-another-user)
- `HSTS`: set to a `Strict-Transport-Security` value, e.g. `max-age=31536000`, to send HSTS on HTTPS requests (direct or forwarded by a trusted proxy). Off by default; add `; includeSubDomains` only if every subdomain serves HTTPS
- `BLOCK_XMLRPC`: set to `1` to refuse `xmlrpc.php` (403), a common password-guessing target. Off by default because Jetpack and the WordPress mobile apps still use it

#### WordPress

The official image's entrypoint creates `wp-config.php` from these variables and supports more: the keys and salts (`WORDPRESS_AUTH_KEY`, …), `WORDPRESS_DB_CHARSET`, and `_FILE` variants for secrets. See [the official image](https://hub.docker.com/_/wordpress) for the full list.

- `WORDPRESS_DB_NAME`: The WordPress database name.
- `WORDPRESS_DB_USER`: The WordPress database user.
- `WORDPRESS_DB_PASSWORD`: The WordPress database password.
- `WORDPRESS_DB_HOST`: The WordPress database host.
- `WORDPRESS_TABLE_PREFIX`: The WordPress database table prefix.
- `WORDPRESS_DEBUG`: Turns on WordPress Debug.
- `FORCE_HTTPS`: Set to `1` to tell WordPress every request is HTTPS. Usually not needed behind a load balancer that terminates TLS, since requests a trusted proxy forwards as HTTPS are detected automatically (see `TRUSTED_PROXIES`). Defaults to `0`.
- `DISALLOW_FILE_EDIT`: set to `1` to turn off the theme and plugin code editors in wp-admin, so a stolen admin login can't be turned into running PHP through them. Recommended for production
- `DISABLE_WP_CRON`: set to `1` to stop WordPress from running scheduled tasks on page loads, when you run them from a real scheduler instead, e.g. `wp cron event run --due-now` every few minutes
- `CORE_UPGRADE_SKIP_NEW_BUNDLED`: on by default, so core updates don't install new default themes and plugins into `wp-content`. Set to `0` to turn it off. A site that defines the constant itself, e.g. in `WORDPRESS_CONFIG_EXTRA`, keeps its own value
- `WORDPRESS_CONFIG_EXTRA`: PHP added to `wp-config.php` when it's created, e.g. `define('WP_HOME', 'https://example.com');`

`FORCE_HTTPS`, `DISALLOW_FILE_EDIT`, `DISABLE_WP_CRON` and `CORE_UPGRADE_SKIP_NEW_BUNDLED` are applied on every request (via `auto_prepend_file`), so they also work for existing sites, whose `wp-config.php` was written when the site was created. Don't also define `DISALLOW_FILE_EDIT` or `DISABLE_WP_CRON` in `WORDPRESS_CONFIG_EXTRA`.

### WP-CLI

[WP-CLI](https://wp-cli.org/) is included and points at the site by default, so it works from any directory:

    docker exec <container> wp plugin list

### Custom Caddy Configuration

`CADDY_SERVER_EXTRA_DIRECTIVES` and `CADDY_EXTRA_CONFIG` take Caddyfile syntax. A block with braces needs several lines; Caddy doesn't accept it on one. In compose, use `|`. For example, serving `image.jpg.webp` instead of `image.jpg` to browsers that accept WebP (the layout of WebP plugins such as WebP Express):

```yaml
    environment:
      CADDY_SERVER_EXTRA_DIRECTIVES: |
        @webp {
          header Accept *image/webp*
          path *.jpg *.jpeg *.png
          file {path}.webp
        }
        rewrite @webp {path}.webp
        header @webp Vary Accept
      CADDY_EXTRA_CONFIG: |
        www.example.com {
          redir https://example.com{uri} permanent
        }
```

### Health Endpoints

- **`/healthz`:** answered by Caddy without PHP or the database, on every site. For load balancers and uptime monitors; it only says the container serves HTTP.
- **`127.0.0.1:2080/healthz.php`:** internal, not reachable from outside the container. The image's Docker `HEALTHCHECK` uses it: healthy when Caddy answers and PHP executes, independent of `SERVER_NAME` and the database, so a database outage doesn't make orchestrators restart the container.

Because `/healthz` is answered before WordPress, no page, post or other content can use that path.

## Sending Email

The image ships [msmtp](https://marlam.de/msmtp/) as `/usr/sbin/sendmail`, which PHP's `mail()` and so `wp_mail()` use. Point it at an SMTP relay with `MSMTP_*` variables. They're read each time a message is sent, so they work for existing sites without touching `wp-config.php`.

| Variable | Default | Purpose |
|---|---|---|
| `MSMTP` | `on` | `off` disables mail |
| `MSMTP_HOST` | – | SMTP relay. Without it, mail isn't sent |
| `MSMTP_PORT` | `587` | Relay port |
| `MSMTP_USER` | – | Login; turns on authentication |
| `MSMTP_PASSWORD` | – | Password for `MSMTP_USER` |
| `MSMTP_FROM` | the message's `From:` | Envelope sender |
| `MSMTP_TLS` | `on` | `off` for relays without TLS |
| `MSMTP_STARTTLS` | `on`, `off` on port 465 | `off` for implicit TLS (port 465) |
| `MSMTP_AUTH` | `on` with `MSMTP_USER`, else `off` | Or a method, e.g. `login` |
| `MSMTP_TLS_CERTCHECK` | `on` | `off` accepts self-signed certificates |
| `MSMTP_SET_FROM_HEADER` | `auto` | `on` replaces the `From:` header with `MSMTP_FROM`, for relays that reject other senders |

Every variable also has a `_FILE` variant, e.g. `MSMTP_PASSWORD_FILE=/run/secrets/smtp_password`, like the official image's `WORDPRESS_*_FILE`. Setting both is an error. msmtp reads the password from the environment or the file itself, so it never appears on a command line or in a file the image writes.

```yaml
services:
  wordpress:
    environment:
      MSMTP_HOST: smtp.example.com
      MSMTP_USER: wordpress@example.com
      MSMTP_PASSWORD_FILE: /run/secrets/smtp_password
      MSMTP_FROM: wordpress@example.com
    secrets:
      - smtp_password

secrets:
  smtp_password:
    file: ./smtp_password.txt
```

Compose mounts a file secret with the host file's owner and permissions (it ignores `uid`, `gid` and `mode` for file secrets), and the container runs as `www-data` (uid 33). On Linux, make the file readable for it, e.g. `sudo chown 33 smtp_password.txt && sudo chmod 400 smtp_password.txt`.

Test it with:

    docker compose exec wordpress wp eval 'var_dump(wp_mail("you@example.com", "test", "test"));'

At startup the container logs where mail goes, or `mail is NOT configured`. Each delivery is logged as one `MSMTP` line with sender, recipients and SMTP status, never the message body or password. A failed mail logs the reason, and `wp_mail()` returns `false`.

SMTP or API plugins (FluentSMTP, WP Mail SMTP, …) send on their own and take precedence over these settings when installed.

## Resource Limits

Set CPU, memory and PHP threads together. FrankenPHP starts two PHP threads per CPU it sees, and each may use up to `memory_limit` (256M):

- **No limit:** on a 32-thread host that's 64 PHP threads, so one site could take about 16 GB. Memory also grows over time, because PHP keeps each thread's peak allocation.
- **CPU limit only:** with `cpus: 1`, FrankenPHP sees one CPU and starts only 2 threads. Two slow requests then block every other visitor.

So set the threads yourself. With `num_threads` (threads at startup) and `max_threads` (FrankenPHP adds threads under load, up to this many), the thread count no longer depends on the CPU limit. The [compose example](examples/compose/compose.yaml) uses values that suit typical sites with low to moderate traffic and ~50–100 MB per request:

```yaml
services:
  wordpress:
    deploy:
      resources:
        limits:
          cpus: 2
          memory: 1G
    environment:
      FRANKENPHP_CONFIG: |
        num_threads 4
        max_threads 8
  db:
    deploy:
      resources:
        limits:
          memory: 1G
```

**Sizing:** `max_threads` × typical memory per request should fit in the memory limit, with headroom for Caddy and OPcache. Raise both for heavy sites (image optimisation plugins, page builders, WooCommerce), e.g. `cpus: 4`, `memory: 3G`, `num_threads 8`, `max_threads 16`.

**At the limit**, the kernel first reclaims page cache. If that isn't enough, it kills FrankenPHP, and the container restarts (`restart: unless-stopped`). Requests in progress at that moment fail.

**Image optimisation plugins** that process images locally (e.g. EWWW Image Optimizer) use every core for a single image through ImageMagick. A CPU limit makes them slower, not broken.

## Sharing wp-content with Another User

Some sites share `wp-content` with another user, e.g. an agency's SFTP account that edits themes and plugins. Both sides then work through a common group, and WordPress has to create files group-writable (`664` files, `775` folders), or the other user can't change or delete what WordPress wrote.

Put the other user in the web user's group (`www-data`, gid 33 inside the container), and make the folders group-owned and setgid, so new files keep that group. On the host (or as root in the container):

    chgrp -R 33 wp-content
    find wp-content -type d -exec chmod 2775 {} +
    find wp-content -type f -exec chmod 664 {} +

Then set `UMASK=0002`. It applies to everything the server runs, and also to `docker exec … wp`, which otherwise starts with Docker's default umask. Plugin, theme and core updates, which WordPress writes with explicit permissions (`FS_CHMOD_FILE`, `FS_CHMOD_DIR`), follow it too: `664` files and `775` folders, keeping setgid when `wp-content` has it. A site that defines those constants itself keeps its own values. Uploads take their folder's permissions, so setgid `2775` folders give `664` uploads.

Other commands started with `docker exec`, e.g. a shell, still use Docker's default umask; run `umask 0002` in them first.

Don't replace the command with `sh -c "umask 0002; exec frankenphp …"`: the image then skips its setup, so a fresh volume gets no WordPress and the startup log stays silent.

`FIX_OWNERSHIP` changes ownership only, never permissions.

## Upgrading and Migrating

Pulling a newer image and recreating the container doesn't update WordPress core in an existing `/var/www/html` volume. WordPress updates itself there.

`docker compose up -V` (`--renew-anon-volumes`) replaces core with the image's bundled version, which can be older than what the site already runs.

Before recreating a container, check that no update is running. `docker compose exec wordpress find /var/www/html -maxdepth 1 -name .maintenance -mmin -10` prints a file if one started in the last 10 minutes; recreating mid-update leaves the site in maintenance mode.

### From the official `wordpress` image

If the old project bind-mounted `/var/www/html`, compose keeps that mount even after you remove it from the file, because the image declares the path a `VOLUME`. Cut over with:

    docker compose up -d --force-recreate --renew-anon-volumes wordpress

Then check that `/var/www/html` is a volume, not the old bind mount:

    docker inspect --format '{{range .Mounts}}{{.Type}} {{.Destination}}{{println}}{{end}}' <container>

A fresh core volume copies WordPress's bundled extras (Akismet, Hello Dolly, the default themes) into `wp-content`. You can delete the ones you don't use.

### MariaDB

The [compose example](examples/compose/compose.yaml) follows MariaDB's current LTS release (`mariadb:lts`) with `MARIADB_AUTO_UPGRADE` on, so the data directory is upgraded when the image moves to a new major version; the image backs up the system tables first. The upgrade is one-way, so take a dump before a major jump anyway:

    docker compose exec db sh -c 'MYSQL_PWD="$MARIADB_ROOT_PASSWORD" mariadb-dump -uroot --all-databases --routines --triggers' > backup.sql

## Extending the Image

The published image has no compiler. To add a PHP extension in your own image, install the build tools for that step, as listed in `$PHPIZE_DEPS`, then remove them again:

```dockerfile
FROM bock/frankenpress:latest
USER root
RUN apt-get update \
    && apt-get install -y --no-install-recommends $PHPIZE_DEPS \
    && install-php-extensions xdebug \
    && apt-get purge -y --auto-remove $PHPIZE_DEPS \
    && rm -rf /var/lib/apt/lists/*
USER www-data
```

When building this repository yourself, `--build-arg WITH_GHOSTSCRIPT=0` leaves out Ghostscript, which saves about 55 MB and removes PDF parsing entirely, but also turns off PDF thumbnails.

## Security Hardening

- **No PHP from uploads:** `.php`, `.phtml`, `.phar` and similar files under `wp-content/uploads` return 404, so a vulnerable upload form can't become remote code execution.
- **No private files:** hidden files and folders (`.git`, `.env`, `.htaccess`, …) and backup or log files (`*.bak`, `*.sql`, `*.log`, …) return 404. `/.well-known/` is still served.
- **Restricted image formats:** Imagick only handles GIF, JPEG, PNG, WebP, AVIF and HEIC, plus reading PDFs for thumbnails. PostScript, SVG and ImageMagick's other formats are refused, which keeps uploads away from rarely audited parsers. In the VIPS images, `VIPS_BLOCK_UNTRUSTED=1` likewise limits libvips to its well-audited loaders, so its PDF, SVG, ImageMagick, OpenEXR, JPEG XL and other rarely audited loaders are off (PDF thumbnails still come from Imagick). libvips blocks them whenever the variable is set, whatever its value, so `VIPS_BLOCK_UNTRUSTED=0` doesn't turn this off.
- **Security headers:** `X-Content-Type-Options`, `Referrer-Policy` and `X-Frame-Options` are added unless WordPress already sent them; the `Server` header is removed. HSTS is available via `HSTS`.
- **No spoofed HTTPS:** `X-Forwarded-Proto` and `CloudFront-Forwarded-Proto` are only honoured from trusted proxies (`TRUSTED_PROXIES`) and dropped from other requests. WordPress's stock `wp-config.php` would otherwise believe any visitor claiming HTTPS.
- **Bounded requests:** slow clients time out, and oversized request bodies get 413 (see `TIMEOUT_*` and `REQUEST_BODY_MAX_BYTES`).
- **Verified downloads:** WP-CLI and the VIPS plugin are pinned to releases and checked against their published checksums.
- **Optional XML-RPC block:** `BLOCK_XMLRPC=1` refuses `xmlrpc.php`.
- **Pinned base images:** every base image is pinned by digest; updates come in as Dependabot pull requests that CI tests first.
- **Fewer libraries, fewer CVEs:** the published image has no compiler and none of ImageMagick's extra codec libraries (OpenEXR, DjVu, WMF, …).
- **WordPress core is writable by the web server user:** dashboard updates need this. Existing sites keep the WordPress version in their `/var/www/html` volume and update through WordPress itself; pulling a newer image doesn't change it.

## Questions

### Why Not Just Use Standard WordPress Images?

The standard WordPress images are a good starting point and can handle many use cases, but require significant modification to scale. You also don't get FrankenPHP app server. Instead, you need to choose Apache or PHP-FPM. We use the WordPress base image but extend it with FrankenPHP & Caddy.

### Why FrankenPHP?

FrankenPHP is built on Caddy, a modern web server written in Go. It's secure, performs well when scaling becomes important, and runs PHP in Go's mature concurrency model, all in a single Docker image.

**[Check out FrankenPHP Here](https://frankenphp.dev/ "FrankenPHP")**

### Why is Non-Root User Important?

An attacker who gets code running in a root container has a much easier path to the host and everything it manages. Running as `www-data` limits a compromise to what that user can do inside the container.


### How to use when behind load balancer or proxy?

_tldr: The default `SERVER_NAME=:80` already serves plain HTTP on port 80 for any hostname. Use another port (e.g. `:8095`) if your proxy expects one._

Working in cloud environments like AWS can be tricky because your traffic is going through a load balancer or some proxy. This means your server name is not what you think your server name is. Your domain hits a proxy dns entry that then hits your application. The application doesn't know your domain. It knows the proxied name. This may seem strange, but it's actually a well established strong architecture pattern.

What about SSL cert? Use `SERVER_NAME=mydomain.com, :80`
Caddy, the underlying application server is flexible enough for multiple entries. Separate multiple values with a comma. It will still request certificate.

What about visitor IPs? Behind a proxy, WordPress would otherwise see every visitor as the proxy's address, so login limiters and security plugins would block everyone at once. The image takes the client IP from `X-Forwarded-For` when the request comes from a trusted proxy; see `TRUSTED_PROXIES` above.

What about HTTPS behind a TLS-terminating proxy? When a trusted proxy sends `X-Forwarded-Proto: https` (or CloudFront's `CloudFront-Forwarded-Proto`), WordPress treats the request as HTTPS, so redirects and URLs use `https://`. `FORCE_HTTPS=1` is still available if your proxy doesn't send either header.
