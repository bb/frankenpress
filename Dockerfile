# syntax=docker/dockerfile:1
# =============================================================================
# FrankenPress - Optimized WordPress Docker Image
# =============================================================================
# This Dockerfile creates a production-ready WordPress container using:
# - FrankenPHP: A modern PHP application server written in Go
# - Caddy: An automatic HTTPS server with integrated reverse proxy
# - WordPress: The world's most popular CMS
#
# The image is optimized for:
# - Size: PHP extensions are compiled in a build stage; the final image is
#   Debian slim plus only the libraries those binaries need (no compiler)
# - Layer ordering based on change frequency (faster rebuilds)
# - Security (runs as non-root user)
# - Performance (OPcache, APCu, object cache extensions)
#
# Build targets:
# - standard (default): WordPress on FrankenPHP
# - vips-ffi: standard + libvips/FFI and the VIPS image editor plugin
# =============================================================================

# -----------------------------------------------------------------------------
# Base Images
# -----------------------------------------------------------------------------
# Every base image is pinned to a digest, so a build always uses exactly the
# images recorded here, and a replaced tag upstream can't change it silently.
# Dependabot (.github/dependabot.yml) opens a pull request when a tag points
# at a new digest or a newer version tag appears; CI tests it before merging.
# The tags below also select the versions: WordPress 7.1.2, FrankenPHP 1.x
# with PHP 8.5 on Debian 13 (Trixie).

# -----------------------------------------------------------------------------
# Stage 1: WordPress Source Files
# -----------------------------------------------------------------------------
# Pull WordPress core files from the official WordPress Docker image
# This stage is used only to extract files, not run WordPress
FROM wordpress:7.1.2@sha256:4abf7a450ee477dde967584f8174d7e03221d224c4971a0c38d84e7254426e64 AS wp

# -----------------------------------------------------------------------------
# Stage 2: PHP Build
# -----------------------------------------------------------------------------
# Compiles the PHP extensions on the official FrankenPHP image, which is
# rebuilt for every PHP release and ships the Vulcain and Brotli Caddy modules,
# the file watcher library and install-php-extensions. It also carries a full
# compiler toolchain (~250 MB), which is why only its /usr/local is copied
# into the final image.
# Tag format: {FRANKENPHP_MAJOR}-php{VERSION}-{DEBIAN_CODENAME} (multi-arch)
# See: https://hub.docker.com/r/dunglas/frankenphp
FROM dunglas/frankenphp:1-php8.5-trixie@sha256:81231b570830952baa3e62db06707996a886ff0a61ca64c77d032c8a110e6bc1 AS php-build

# bash with pipefail, so a library without a Debian package fails the build
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# PHP extensions installed via install-php-extensions:
# - bcmath: Arbitrary precision mathematics (WooCommerce, etc.)
# - exif: Image metadata extraction
# - gd: Image manipulation library
# - intl: Internationalization support
# - mysqli: MySQL database driver
# - zip: Archive handling
# - imagick: Advanced image processing (alternative to GD)
# - memcached: Object caching backend
# - apcu: In-memory user cache
# - redis: Object caching and sessions
# - igbinary/msgpack: Efficient serialization for caching
# - ffi: only enabled in the vips-ffi image (its .ini is removed here)
#
# OPcache is not installed here: it is built into PHP 8.5 and always present.
#
# Afterwards, every shared library the PHP and FrankenPHP binaries link
# against is mapped to its Debian package, so the final stage can install
# exactly those (written to /runtime-packages.txt), and files only needed for
# linking are dropped from /usr/local. Libraries are looked up by their
# resolved /usr path first: for Debian's t64 packages the /lib path only
# shows up as a "diversion by <package>" line, which is parsed as well.
#
# See: https://github.com/mlocati/docker-php-extension-installer
RUN install-php-extensions \
        bcmath \
        exif \
        gd \
        intl \
        mysqli \
        zip \
        imagick \
        memcached \
        apcu \
        redis \
        igbinary \
        msgpack \
        ffi \
    && rm -f "$PHP_INI_DIR/conf.d/docker-php-ext-ffi.ini" \
    && find /usr/local -type f \( -name '*.so' -o -name '*.so.*' -o -perm -u+x \) -print0 \
        | { xargs -0 ldd 2>/dev/null || true; } \
        | awk '$2 == "=>" && $3 ~ /^\// { print $3 }' \
        | grep -v '^/usr/local/' \
        | sort -u \
        | while read -r lib; do \
            dpkg -S "$(realpath "$lib")" 2>/dev/null || dpkg -S "$lib" 2>/dev/null || { echo "no package owns $lib" >&2; exit 1; }; \
        done \
        | sed -E 's/^diversion by ([^ ]+) (from|to): .*/\1:/' \
        | cut -d: -f1 \
        | sort -u > /runtime-packages.txt \
    && echo "Runtime packages:" && cat /runtime-packages.txt \
    && rm -rf /usr/local/lib/libwatcher-c.a \
        /usr/local/php/man

# -----------------------------------------------------------------------------
# Stage 3: Standard FrankenPress Image
# -----------------------------------------------------------------------------
# Must be the same Debian release as the php-build stage above
FROM debian:13-slim@sha256:a99cfc517144bc59b1978475ec53b46ecabec7e43635402ee5b77cc54cd1b20a AS standard

# -----------------------------------------------------------------------------
# Metadata Labels
# -----------------------------------------------------------------------------
# OCI-compliant image labels for container registries and tooling. CI adds
# source, revision, version and creation date.
# See: https://github.com/opencontainers/image-spec/blob/main/annotations.md
LABEL org.opencontainers.image.title=FrankenPress \
      org.opencontainers.image.description="Optimized WordPress containers to run everywhere. Built with FrankenPHP & Caddy." \
      org.opencontainers.image.source=https://github.com/bb/frankenpress \
      org.opencontainers.image.licenses=MIT

# -----------------------------------------------------------------------------
# Environment Variables
# -----------------------------------------------------------------------------
# PHP_INI_DIR, XDG_* and GODEBUG mirror the FrankenPHP image this is built from.
# FORCE_HTTPS: Set to 1 to force HTTPS in WordPress (sets $_SERVER['HTTPS'])
# PAGER: Default pager for terminal sessions (useful for WP-CLI)
ENV PHP_INI_DIR=/usr/local/etc/php \
    XDG_CONFIG_HOME=/config \
    XDG_DATA_HOME=/data \
    GODEBUG=cgocheck=0 \
    PHPIZE_DEPS="autoconf dpkg-dev file g++ gcc libc-dev make pkg-config re2c" \
    FORCE_HTTPS=0 \
    PAGER=more

# -----------------------------------------------------------------------------
# System Dependencies
# -----------------------------------------------------------------------------
# - ca-certificates: SSL/TLS certificate validation
# - curl: HTTP client for WP-CLI and the healthcheck
# - xz-utils: unpacks the PHP source when install-php-extensions is used in
#   images built on top of this one
# - ghostscript: lets Imagick render thumbnails of uploaded PDFs. Build with
#   --build-arg WITH_GHOSTSCRIPT=0 to leave it out (~50 MB, and no PDF parsing
#   at all) if you don't need PDF thumbnails.
# - the runtime libraries of PHP, FrankenPHP and the extensions, as found in
#   the build stage. Recommended packages are skipped, which also keeps out
#   ImageMagick's extra coders (OpenEXR, DjVu, WMF, ...).
# - libheif plugins: AVIF encoding (aomenc) and AVIF/HEIC decoding (dav1d,
#   libde265) for Imagick. libheif only recommends them, so the library
#   list above doesn't pull them in.
ARG WITH_GHOSTSCRIPT=1
ARG DEBIAN_FRONTEND=noninteractive
RUN --mount=type=bind,from=php-build,source=/runtime-packages.txt,target=/mnt/runtime-packages.txt \
    apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        libheif-plugin-aomenc \
        libheif-plugin-dav1d \
        libheif-plugin-libde265 \
        xz-utils \
        $( [ "$WITH_GHOSTSCRIPT" = 1 ] && echo ghostscript ) \
        $(cat /mnt/runtime-packages.txt) \
    && rm -rf /var/lib/apt/lists/* \
        /tmp/* \
        /var/tmp/* \
        /usr/share/doc/* \
        /usr/share/man/*

# PHP, FrankenPHP (whose binary keeps its cap_net_bind_service capability, so
# it can bind ports 80/443 as a non-root user), the extensions and their
# configuration
COPY --from=php-build /usr/local /usr/local
# PHP source, headers (in /usr/local) and PHPIZE_DEPS keep install-php-extensions
# working in images built on top of this one: it installs the compiler for the
# build and removes it again, e.g. FROM bock/frankenpress / USER root /
# RUN install-php-extensions xdebug
COPY --from=php-build /usr/src/php.tar.xz /usr/src/php.tar.xz.asc /usr/src/
# Fail the build if any binary or extension still misses a library
RUN ldconfig \
    && missing=$(find /usr/local -type f \( -name '*.so' -o -name '*.so.*' -o -perm -u+x \) -exec ldd {} + 2>/dev/null | grep 'not found' | sort -u) \
    && { [ -z "$missing" ] || { echo "Missing runtime libraries:" >&2; echo "$missing" >&2; exit 1; }; } \
    && mkdir -p /etc/caddy /data/caddy /config/caddy /var/www/html

# -----------------------------------------------------------------------------
# PHP Configuration
# -----------------------------------------------------------------------------
# Consolidated into a single layer to reduce image size.
#
# 1. Base PHP.ini: Start with production-recommended settings
# 2. OpCache settings: Configure bytecode caching for performance
#    - memory_consumption: 256MB for caching compiled scripts
#    - interned_strings_buffer: 16MB for string interning
#    - max_accelerated_files: Cache up to 20000 files (core alone has ~1500;
#      WooCommerce and page builders add thousands more)
#    - revalidate_freq: Check for changes every 2 seconds
#    See: https://www.php.net/manual/en/opcache.configuration.php
#
# 3. Error logging: Production-safe error handling
#    - Errors logged to stderr for container log aggregation
#    - Display errors disabled for security
#    - Comprehensive error reporting enabled
#    See: https://github.com/docker-library/wordpress/issues/420
#
# 4. Security: Hide PHP version from HTTP headers
RUN cp $PHP_INI_DIR/php.ini-production $PHP_INI_DIR/php.ini \
    && { \
        echo 'opcache.memory_consumption=256'; \
        echo 'opcache.interned_strings_buffer=16'; \
        echo 'opcache.max_accelerated_files=20000'; \
        echo 'opcache.revalidate_freq=2'; \
    } > $PHP_INI_DIR/conf.d/opcache-recommended.ini \
    && { \
        echo 'error_reporting = E_ERROR | E_WARNING | E_PARSE | E_CORE_ERROR | E_CORE_WARNING | E_COMPILE_ERROR | E_COMPILE_WARNING | E_RECOVERABLE_ERROR'; \
        echo 'display_errors = Off'; \
        echo 'display_startup_errors = Off'; \
        echo 'log_errors = On'; \
        echo 'error_log = /dev/stderr'; \
        echo 'ignore_repeated_errors = On'; \
        echo 'ignore_repeated_source = Off'; \
        echo 'html_errors = Off'; \
    } > $PHP_INI_DIR/conf.d/error-logging.ini \
    && echo 'expose_php = Off' > $PHP_INI_DIR/conf.d/expose_php.ini

# -----------------------------------------------------------------------------
# WP-CLI Installation
# -----------------------------------------------------------------------------
# WordPress Command Line Interface for managing WordPress from the terminal.
# Useful for plugin/theme management, database operations, and automation.
# Pinned to a release and verified against its published SHA-512; update both
# together from https://github.com/wp-cli/wp-cli/releases
# See: https://wp-cli.org/
ARG WP_CLI_VERSION=2.12.0
ARG WP_CLI_SHA512=be928f6b8ca1e8dfb9d2f4b75a13aa4aee0896f8a9a0a1c45cd5d2c98605e6172e6d014dda2e27f88c98befc16c040cbb2bd1bfa121510ea5cdf5f6a30fe8832
RUN curl -fsSL -o /usr/local/bin/wp \
        "https://github.com/wp-cli/wp-cli/releases/download/v${WP_CLI_VERSION}/wp-cli-${WP_CLI_VERSION}.phar" \
    && echo "${WP_CLI_SHA512}  /usr/local/bin/wp" | sha512sum -c - \
    && chmod +x /usr/local/bin/wp

# -----------------------------------------------------------------------------
# User and Permissions Setup
# -----------------------------------------------------------------------------
# Configure the container to run as a non-root user for security.
# The user is created before the WordPress files are copied so they can be
# copied with the right owner; a recursive chown afterwards would duplicate
# all of WordPress into another layer.
#
# Steps:
# 1. Create user if it doesn't exist (default: www-data)
# 2. Set ownership of the Caddy and web root directories
#
# NOTE: On some platforms (e.g., AWS ECS), volume mounts are owned by root.
# Start the container as root with FIX_PERMISSIONS=1 to repair ownership at
# startup and then drop to USER_NAME (see frankenpress-entrypoint.sh).
ARG USER_NAME=www-data
ENV FRANKENPRESS_USER=${USER_NAME}

RUN if id "${USER_NAME}" >/dev/null 2>&1; then \
        echo "User ${USER_NAME} already exists"; \
    else \
        useradd -m ${USER_NAME}; \
    fi \
    && chown -R ${USER_NAME}:${USER_NAME} /data/caddy \
        /config/caddy \
        /var/www/html

# -----------------------------------------------------------------------------
# WordPress Core Files
# -----------------------------------------------------------------------------
# Copy WordPress core files from the official WordPress image.
# This includes:
# - /usr/src/wordpress: WordPress core files (copied to /var/www/html on start)
# - docker-entrypoint.sh: WordPress initialization script
#
# PHP configuration is deliberately NOT copied: the WordPress image is built
# against a different PHP version, and its docker-php-ext-*.ini loaders break
# extensions here (e.g. OPcache is built into PHP 8.5 and can't be loaded).
COPY --from=wp --chown=${USER_NAME}:${USER_NAME} /usr/src/wordpress /usr/src/wordpress
COPY --from=wp --chown=${USER_NAME}:${USER_NAME} /usr/local/bin/docker-entrypoint.sh /usr/local/bin/
COPY --chmod=755 frankenpress-entrypoint.sh /usr/local/bin/frankenpress-entrypoint.sh

# -----------------------------------------------------------------------------
# WordPress and Entrypoint Customization
# -----------------------------------------------------------------------------
# Modify the WordPress Docker entrypoint to work with FrankenPHP instead of PHP-FPM.
# Also inject WordPress configuration for new sites:
# - FS_METHOD=direct: Direct filesystem access (no FTP needed)
# - set_time_limit(300): Allow long-running operations (imports, updates, etc.)
# HTTPS detection and the DISALLOW_FILE_EDIT/DISABLE_WP_CRON switches live in
# frankenpress-prepend.php instead, so they also reach existing sites, whose
# wp-config.php the entrypoint never rewrites.
RUN sed -i \
        -e 's/\[ "$1" = '\''php-fpm'\'' \]/\[\[ "$1" == frankenphp* \]\]/g' \
        -e 's/php-fpm/frankenphp/g' \
        /usr/local/bin/docker-entrypoint.sh \
    && sed -i 's/<?php/<?php define( "FS_METHOD", "direct" ); set_time_limit(300); /g' /usr/src/wordpress/wp-config-docker.php

# -----------------------------------------------------------------------------
# Custom Configuration Files
# -----------------------------------------------------------------------------
# These files are copied last as they're most likely to change during development.
# Placing them here maximizes Docker build cache efficiency.
#
# - php.ini: WordPress-specific PHP settings (upload size, execution time, etc.)
# - Caddyfile: Caddy web server configuration (routing, headers, compression)
# - imagemagick-policy.xml: limits Imagick to the formats WordPress needs
# - wp-cli.yml: points WP-CLI at the site, so `wp` works from any directory
# - healthz.php: served only on 127.0.0.1:2080 for the HEALTHCHECK below
# - prepend.php: runtime settings loaded before every request (php.ini)
COPY php.ini $PHP_INI_DIR/conf.d/wp.ini
COPY Caddyfile /etc/caddy/Caddyfile
COPY imagemagick-policy.xml /etc/ImageMagick-7/policy.xml
COPY wp-cli.yml /usr/local/etc/wp-cli.yml
COPY frankenpress-prepend.php /usr/local/share/frankenpress/prepend.php
ENV WP_CLI_CONFIG_PATH=/usr/local/etc/wp-cli.yml
RUN mkdir -p /usr/local/share/frankenpress/health \
    && echo '<?php echo "ok";' > /usr/local/share/frankenpress/health/healthz.php

# Healthy when Caddy answers and PHP executes. Deliberately independent of the
# database, so a database outage doesn't make orchestrators restart the
# container.
HEALTHCHECK --interval=30s --timeout=5s --start-period=30s --retries=3 \
    CMD curl -fsS http://127.0.0.1:2080/healthz.php || exit 1

# -----------------------------------------------------------------------------
# Container Runtime Configuration
# -----------------------------------------------------------------------------
EXPOSE 80 443 443/udp

# Define persistent volume mount point for WordPress files
VOLUME /var/www/html

# Set working directory for all subsequent commands and container shell access
WORKDIR /var/www/html

# Switch to non-root user (all subsequent commands run as this user)
USER $USER_NAME

# -----------------------------------------------------------------------------
# Entrypoint and Command
# -----------------------------------------------------------------------------
# Entrypoint: optional ownership repair (FIX_PERMISSIONS=1 when started as
# root), then the WordPress initialization script (copies core files, sets up db)
# Command: Start FrankenPHP server with Caddy configuration
#
# The WordPress entrypoint handles:
# - Copying WordPress core files to /var/www/html if not present
# - Generating wp-config.php from environment variables
# - Database connection and installation
#
# To override the command (e.g., for debugging):
# docker run -it frankenpress bash
ENTRYPOINT ["/usr/local/bin/frankenpress-entrypoint.sh"]
CMD ["frankenphp", "run", "--config", "/etc/caddy/Caddyfile"]

# -----------------------------------------------------------------------------
# Stage 4: VIPS/FFI Variant
# -----------------------------------------------------------------------------
# Adds libvips (with HEIF/AVIF support), enables the FFI extension built in
# the php-build stage, and installs the vips-image-editor-ffi plugin so
# WordPress uses libvips for image processing.
# Build with: docker build --target vips-ffi .
FROM standard AS vips-ffi

ARG USER_NAME=www-data

# Only let libvips use its fuzzed, well-audited loaders. This blocks its
# Poppler (PDF), librsvg (SVG) and ImageMagick loaders, which libvips would
# otherwise pick by sniffing file contents, bypassing imagemagick-policy.xml
# for PDF and SVG. WordPress still renders PDF thumbnails via Imagick.
# See: https://www.libvips.org/API/current/func.block_untrusted_set.html
ENV VIPS_BLOCK_UNTRUSTED=1

USER root

RUN apt-get update && apt-get install -y --no-install-recommends \
        libvips42 \
        libheif1 \
        libaom3 \
        libheif-plugin-aomdec \
        libheif-plugin-aomenc \
    && rm -rf /var/cache/apt/archives \
        /var/lib/apt/lists/*

# Pinned plugin release, verified against the SHA-256 GitHub records for the asset.
# Unpacked with PHP's zip extension so the image doesn't need unzip.
ADD --checksum=sha256:4fbfa7b1b17e8c1b618e767a9dc6308051ed0de2ab08dada6c220480e14d7771 \
    https://github.com/notglossy/vips-image-editor-ffi/releases/download/v3.1.0/vips-image-editor-ffi-3.1.0.zip \
    /tmp/vips-image-editor-ffi.zip
RUN php -r '$z = new ZipArchive(); $z->open("/tmp/vips-image-editor-ffi.zip") === true && $z->extractTo("/usr/src/wordpress/wp-content/plugins/") || exit(1);' \
    && rm -f /tmp/vips-image-editor-ffi.zip \
    && chown -R ${USER_NAME}:${USER_NAME} /usr/src/wordpress/wp-content/plugins \
    && echo 'zend.max_allowed_stack_size=-1' >> $PHP_INI_DIR/conf.d/stack-size.ini \
    && { \
        echo 'extension=ffi'; \
        echo 'ffi.enable=true'; \
    } > $PHP_INI_DIR/conf.d/docker-php-ext-ffi.ini

USER $USER_NAME

# -----------------------------------------------------------------------------
# Default Target
# -----------------------------------------------------------------------------
# Keep the standard image as the default when no --target is given.
FROM standard
