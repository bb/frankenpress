# TODO

Open items from the image review and the comparison with
[TrafeX/docker-wordpress](https://github.com/TrafeX/docker-wordpress), by priority.

## High

- [ ] **Keep WordPress core inside the image.** Today core lives in the `/var/www/html` volume, so a newer image never updates existing sites, and core files are writable by the web server user, which lets an attacker with PHP execution backdoor them.
  - **Proposal:** copy core into the image (read-only, root-owned), make only `wp-content` a volume, and set `WP_AUTO_UPDATE_CORE=false` because updates come with the image. This is TrafeX's model.
  - **Cost:** it's a breaking change for existing deployments, which need a migration path. Dashboard core updates go away, and it needs our own entrypoint instead of the official one. Ship it as a separate variant or a major version.

## Medium

- [ ] **Set `DOCKERHUB_DESCRIPTION_TOKEN`.** The Docker Hub description sync failed with `Forbidden` on its first run: it needs a token with the "Read, Write, Delete" scope, and the publishing token is only "Read & Write". Create one at https://app.docker.com → Personal access tokens, then run `gh secret set DOCKERHUB_DESCRIPTION_TOKEN --repo bb/frankenpress`, then re-run the "Update Docker Hub Description" workflow.
- [ ] **Confirm the first keepalive run** (scheduled Sunday 2026-10-04, 01:00 UTC). Check that the `keepalive` job succeeds and the workflow stays `active`.

## Low

- [ ] **Reduce OpenEXR in the VIPS image.** The standard image no longer contains OpenEXR, but libvips itself depends on it, so the VIPS image still carries its 22 HIGH/CRITICAL findings. Check whether `VIPS_BLOCK_UNTRUSTED` already keeps uploads away from libvips's EXR loader. If it doesn't, check whether blocking `exrload` with `vips_operation_block_set` is practical.
- [ ] **Decide on notglossy/frankenpress#17.** That upstream PR only has the first upgrade commit; later fixes are only here. Update it, open a new one, or close it.
- [ ] **Clean up the stuck workflow runs.** Runs `36923747112`, `36925200760` and `36925308009` have been "queued" since 2026-10-01. The API can neither cancel nor delete them; ask GitHub Support.
