# TODO

Open items from the image review and the comparison with
[TrafeX/docker-wordpress](https://github.com/TrafeX/docker-wordpress), by priority.

## High

- [ ] **Keep WordPress core inside the image.** Today core lives in the `/var/www/html` volume, so a newer image never updates existing sites, and core files are writable by the web server user, which lets an attacker with PHP execution backdoor them.
  - **Proposal:** copy core into the image (read-only, root-owned), make only `wp-content` a volume, and set `WP_AUTO_UPDATE_CORE=false` because updates come with the image. This is TrafeX's model.
  - **Cost:** it's a breaking change for existing deployments, which need a migration path. Dashboard core updates go away, and it needs our own entrypoint instead of the official one. Ship it as a separate variant or a major version.

## Medium

- [ ] **Confirm the first Dependabot base-image update.** Dependabot already parses the digest-pinned `FROM` lines (wordpress, dunglas/frankenphp, debian) and reports them current. When the first update PR arrives, check that CI runs on it, that it merges automatically (`dependabot-automerge.yml`, not for major versions), and that the image build on main starts afterwards and publishes.
- [ ] **Confirm the first keepalive run** (scheduled Sunday 2026-10-04, 01:00 UTC). Check that the `keepalive` job succeeds and the workflow stays `active`.

## Low

- [ ] **Revisit the MariaDB client wrapper** (`frankenpress-mariadb.sh`) when WP-CLI releases a version after 2.12 with db-command 3.x, which passes `--skip-ssl-verify-server-cert` itself. `wp db` won't need the wrapper then; decide whether the plain `mariadb`/`mariadb-dump` commands should keep skipping certificate verification.
