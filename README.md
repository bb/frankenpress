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

- `SERVER_NAME`: change the addresses on which to listen. Real hostnames get a publicly trusted certificate (Let's Encrypt/ZeroSSL) automatically; `localhost` and IP addresses use Caddy's local CA
- `CADDY_GLOBAL_OPTIONS`: inject global options (debug most common)
- `FRANKENPHP_CONFIG`: inject config under the frankenphp directive
- `TRUSTED_PROXIES`: proxies whose `X-Forwarded-For` header is trusted for the client IP, as space-separated CIDRs. Defaults to `private_ranges` (10/8, 172.16/12, 192.168/16, 127/8 and their IPv6 equivalents). Set it to your load balancer's range so other hosts on a private network can't spoof their IP

#### Wordpress

- `WORDPRESS_DB_NAME`: The WordPress database name.
- `WORDPRESS_DB_USER`: The WordPress database user.
- `WORDPRESS_DB_PASSWORD`: The WordPress database password.
- `WORDPRESS_DB_HOST`: The WordPress database host.
- `WORDPRESS_TABLE_PREFIX`: The WordPress database table prefix.
- `WORDPRESS_DEBUG`: Turns on WordPress Debug.
- `FORCE_HTTPS`: Set to `1` to tell WordPress every request is HTTPS. Useful behind a load balancer that terminates TLS. Defaults to `0`.
- `WORDPRESS_CONFIG_EXTRA`: use this for adding WP_HOME, WP_SITEURL, etc

### WP-CLI

[WP-CLI](https://wp-cli.org/) is included and points at the site by default, so it works from any directory:

    docker exec <container> wp plugin list

### Healthcheck

The image's `HEALTHCHECK` runs a tiny PHP script on an internal port (`127.0.0.1:2080`, not reachable from outside the container). The container is healthy when Caddy answers and PHP executes, independent of `SERVER_NAME` and of the database, so a database outage doesn't make orchestrators restart it.

## Security Hardening

- **No PHP from uploads:** `.php`, `.phtml`, `.phar` and similar files under `wp-content/uploads` return 404, so a vulnerable upload form can't become remote code execution.
- **No private files:** hidden files and folders (`.git`, `.env`, `.htaccess`, …) and backup or log files (`*.bak`, `*.sql`, `*.log`, …) return 404. `/.well-known/` is still served.
- **Restricted image formats:** Imagick only handles GIF, JPEG, PNG, WebP, AVIF and HEIC, plus reading PDFs for thumbnails. PostScript, SVG and ImageMagick's other formats are refused, which keeps uploads away from rarely audited parsers. In the VIPS images, `VIPS_BLOCK_UNTRUSTED=1` likewise limits libvips to its well-audited loaders, so its PDF, SVG and ImageMagick loaders are off (PDF thumbnails still come from Imagick).
- **Security headers:** `X-Content-Type-Options`, `Referrer-Policy` and `X-Frame-Options` are added unless WordPress already sent them.
- **Verified downloads:** WP-CLI and the VIPS plugin are pinned to releases and checked against their published checksums.
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

_tldr: Use a port (ie :80, :8095, etc) for SERVER_NAME env variable._

Working in cloud environments like AWS can be tricky because your traffic is going through a load balancer or some proxy. This means your server name is not what you think your server name is. Your domain hits a proxy dns entry that then hits your application. The application doesn't know your domain. It knows the proxied name. This may seem strange, but it's actually a well established strong architecture pattern.

What about SSL cert? Use `SERVER_NAME=mydomain.com, :80`
Caddy, the underlying application server is flexible enough for multiple entries. Separate multiple values with a comma. It will still request certificate.

What about visitor IPs? Behind a proxy, WordPress would otherwise see every visitor as the proxy's address, so login limiters and security plugins would block everyone at once. The image takes the client IP from `X-Forwarded-For` when the request comes from a trusted proxy; see `TRUSTED_PROXIES` above.
