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
- `CADDY_GLOBAL_OPTIONS`: inject global options (debug most common)
- `FRANKENPHP_CONFIG`: inject config under the frankenphp directive
- `TRUSTED_PROXIES`: proxies whose `X-Forwarded-For` header is trusted for the client IP, as space-separated CIDRs. Defaults to `private_ranges` (10/8, 172.16/12, 192.168/16, 127/8 and their IPv6 equivalents). Set it to your load balancer's range so other hosts on a private network can't spoof their IP. Trusted proxies can also mark a request as HTTPS via `X-Forwarded-Proto` or `CloudFront-Forwarded-Proto`
- `FIX_PERMISSIONS`: set to `1` and start the container as root (`--user root`, or `user: root` in compose) to repair ownership of mounted folders at startup. Useful when bind mounts or platforms like AWS ECS hand the container root-owned folders, so uploads or certificates can't be written. Files not owned by the web user in `/var/www/html`, `/data/caddy` and `/config/caddy` are chowned (symlinks themselves, never their targets), then the server drops to `www-data`. Without `FIX_PERMISSIONS`, the image runs as `www-data` as before
- `HSTS`: set to a `Strict-Transport-Security` value, e.g. `max-age=31536000`, to send HSTS on HTTPS requests (direct or forwarded by a trusted proxy). Off by default; add `; includeSubDomains` only if every subdomain serves HTTPS
- `BLOCK_XMLRPC`: set to `1` to refuse `xmlrpc.php` (403), a common password-guessing target. Off by default because Jetpack and the WordPress mobile apps still use it

#### Wordpress

- `WORDPRESS_DB_NAME`: The WordPress database name.
- `WORDPRESS_DB_USER`: The WordPress database user.
- `WORDPRESS_DB_PASSWORD`: The WordPress database password.
- `WORDPRESS_DB_HOST`: The WordPress database host.
- `WORDPRESS_TABLE_PREFIX`: The WordPress database table prefix.
- `WORDPRESS_DEBUG`: Turns on WordPress Debug.
- `FORCE_HTTPS`: Set to `1` to tell WordPress every request is HTTPS. Usually not needed behind a load balancer that terminates TLS, since requests a trusted proxy forwards as HTTPS are detected automatically (see `TRUSTED_PROXIES`). Defaults to `0`.
- `DISALLOW_FILE_EDIT`: set to `1` to turn off the theme and plugin code editors in wp-admin, so a stolen admin login can't be turned into running PHP through them. Recommended for production
- `DISABLE_WP_CRON`: set to `1` to stop WordPress from running scheduled tasks on page loads, when you run them from a real scheduler instead, e.g. `wp cron event run --due-now` every few minutes

`FORCE_HTTPS`, `DISALLOW_FILE_EDIT` and `DISABLE_WP_CRON` are applied before every request (via `auto_prepend_file`), so they also work for existing sites, whose `wp-config.php` was written when the site was created. Don't also define `DISALLOW_FILE_EDIT` or `DISABLE_WP_CRON` in `WORDPRESS_CONFIG_EXTRA`.
- `WORDPRESS_CONFIG_EXTRA`: use this for adding WP_HOME, WP_SITEURL, etc

### WP-CLI

[WP-CLI](https://wp-cli.org/) is included and points at the site by default, so it works from any directory:

    docker exec <container> wp plugin list

### Healthcheck

`/healthz` answers `ok` straight from Caddy, without PHP or the database, for load balancers and uptime checks.

The image's `HEALTHCHECK` runs a tiny PHP script on an internal port (`127.0.0.1:2080`, not reachable from outside the container). The container is healthy when Caddy answers and PHP executes, independent of `SERVER_NAME` and of the database, so a database outage doesn't make orchestrators restart it.

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
- **Restricted image formats:** Imagick only handles GIF, JPEG, PNG, WebP, AVIF and HEIC, plus reading PDFs for thumbnails. PostScript, SVG and ImageMagick's other formats are refused, which keeps uploads away from rarely audited parsers. In the VIPS images, `VIPS_BLOCK_UNTRUSTED=1` likewise limits libvips to its well-audited loaders, so its PDF, SVG and ImageMagick loaders are off (PDF thumbnails still come from Imagick).
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

FrankenPHP is built on Caddy, a modern web server built in Go. It is secure & performs well when scaling becomes important. It also allows us to take advantage of built-in mature concurrency through goroutines into a single Docker image. high performance in a single lean image.

**[Check out FrankenPHP Here](https://frankenphp.dev/ "FrankenPHP")**

### Why is Non-Root User Important?

It is good practice to avoid using root users in your Docker images for security purposes. If a questionable individual gets access into your running Docker container with root account then they could have access to the cluster and all the resources it manages. This could be problematic. On the other hand, by creating a user specific to the Docker image, narrows the threat to only the image itself. It is also important to note that the base WordPress images also create non-root users by default.


### How to use when behind load balancer or proxy?

_tldr: The default `SERVER_NAME=:80` already serves plain HTTP on port 80 for any hostname. Use another port (e.g. `:8095`) if your proxy expects one._

Working in cloud environments like AWS can be tricky because your traffic is going through a load balancer or some proxy. This means your server name is not what you think your server name is. Your domain hits a proxy dns entry that then hits your application. The application doesn't know your domain. It knows the proxied name. This may seem strange, but it's actually a well established strong architecture pattern.

What about SSL cert? Use `SERVER_NAME=mydomain.com, :80`
Caddy, the underlying application server is flexible enough for multiple entries. Separate multiple values with a comma. It will still request certificate.

What about visitor IPs? Behind a proxy, WordPress would otherwise see every visitor as the proxy's address, so login limiters and security plugins would block everyone at once. The image takes the client IP from `X-Forwarded-For` when the request comes from a trusted proxy; see `TRUSTED_PROXIES` above.

What about HTTPS behind a TLS-terminating proxy? When a trusted proxy sends `X-Forwarded-Proto: https` (or CloudFront's `CloudFront-Forwarded-Proto`), WordPress treats the request as HTTPS, so redirects and URLs use `https://`. `FORCE_HTTPS=1` is still available if your proxy doesn't send either header.
