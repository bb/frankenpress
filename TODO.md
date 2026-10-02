# TODO

Open items from the image review and the comparison with
[TrafeX/docker-wordpress](https://github.com/TrafeX/docker-wordpress), by priority.

## High

- [ ] **Keep WordPress core inside the image.** Today core lives in the `/var/www/html` volume, so a newer image never updates existing sites, and core files are writable by the web server user, which lets an attacker with PHP execution backdoor them.
  - **Proposal:** copy core into the image (read-only, root-owned), make only `wp-content` a volume, and set `WP_AUTO_UPDATE_CORE=false` because updates come with the image. This is TrafeX's model.
  - **Cost:** it's a breaking change for existing deployments, which need a migration path. Dashboard core updates go away, and it needs our own entrypoint instead of the official one. Ship it as a separate variant or a major version.

## Medium

- [ ] **Detect HTTPS behind proxies automatically.** `FORCE_HTTPS` is all or nothing. FrankenPHP doesn't set `$_SERVER['HTTPS']` from `X-Forwarded-Proto`, even for trusted proxies. TrafeX maps `X-Forwarded-Proto` and `CloudFront-Forwarded-Proto` to `HTTPS`. The check must only trust the header from `TRUSTED_PROXIES`.
- [ ] **Shrink the image.**
  - **The problem:** the `dunglas/frankenphp` base ships a full compiler toolchain (gcc, g++, cpp, headers, perl), about 250 MB unpacked, that's only needed to build extensions.
  - **Option A, separate build stage:** build extensions in a builder stage and copy the binaries and runtime libraries into a slim final stage.
  - **Option B, Alpine:** 69 MB compressed against 200 MB, but musl; FrankenPHP recommends glibc for performance.
  - **Today:** standard is 976 MB, VIPS 1.03 GB.
- [ ] **Remove ImageMagick's extra coders package.** Most of the CVEs Trivy finds in our layers come from libraries pulled in by `libmagickcore-7.q16-10-extra` (22 in OpenEXR, plus libtiff and others). The ImageMagick policy already blocks those formats; removing the package would remove the code as well. Check that HEIC/AVIF support survives.
- [ ] **Set `DOCKERHUB_DESCRIPTION_TOKEN`.** The Docker Hub description sync needs a token with the "Read, Write, Delete" scope; the publishing token is only "Read & Write". Create one at https://app.docker.com → Personal access tokens, then run `gh secret set DOCKERHUB_DESCRIPTION_TOKEN --repo bb/frankenpress`.
- [ ] **Confirm the first keepalive run** (scheduled Sunday 2026-10-04, 01:00 UTC). Check that the `keepalive` job succeeds and the workflow stays `active`.

## Low

- [ ] **Avoid the duplicated FrankenPHP binary.** `setcap` copies the 51 MB binary into a new layer. The only way around it is listening on an unprivileged port (e.g. 8080) instead of 80/443, which changes how people run the image.
- [ ] **Replace leftover notglossy labels.** The Dockerfile `LABEL`s still say `vendor="Not Glossy"` and point `image.source` at notglossy (CI overrides `source`, but not `vendor`).
- [ ] **Remove the redundant `ENV PHP_INI_SCAN_DIR`.** It repeats PHP's default.
- [ ] **Offer an opt-in block for `xmlrpc.php`.** It's a common password-guessing target; some plugins (Jetpack, mobile apps) still need it.
- [ ] **Offer an option to drop Ghostscript** for sites that don't need PDF thumbnails. That saves ~50 MB (Ghostscript, fonts, poppler-data) and removes the remaining PDF attack surface.
- [ ] **Add a `SECURITY.md`** that says how to report vulnerabilities, as TrafeX does.
- [ ] **Decide on notglossy/frankenpress#17.** That upstream PR only has the first upgrade commit; later fixes are only here. Update it, open a new one, or close it.
- [ ] **Clean up the stuck workflow runs.** Runs `36923747112`, `36925200760` and `36925308009` have been "queued" since 2026-10-01. The API can neither cancel nor delete them; ask GitHub Support.
