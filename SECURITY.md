# Security Policy

## Supported Versions

Only the latest build of each published tag receives fixes. Images are rebuilt weekly, which picks up PHP, FrankenPHP, Debian and WordPress security releases. Pin a dated tag (see [Pinning a Version](README.md#pinning-a-version)) only as long as you keep updating it.

WordPress core inside an existing `/var/www/html` volume is updated by WordPress itself, not by pulling a new image.

## Reporting a Vulnerability

Please report vulnerabilities privately through GitHub: open the repository's **Security** tab and choose **Report a vulnerability**, or go to https://github.com/bb/frankenpress/security/advisories/new.

Please don't open a public issue for security problems. Vulnerabilities in WordPress itself, plugins or themes belong with their maintainers; see https://wordpress.org/about/security/.
