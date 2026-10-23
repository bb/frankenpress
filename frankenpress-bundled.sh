# Sourced by the WordPress entrypoint right before it copies core into an
# empty /var/www/html (patched in by the Dockerfile), with sourceTarArgs
# holding the tar options for /usr/src/wordpress.
#
# The entrypoint skips bundled plugins and themes that already exist in
# wp-content, but copies every missing one, and Hello Dolly (a single file)
# always. With wp-content kept outside the core volume, e.g. bind-mounted,
# every fresh core volume brings back the extras a site had deleted.
# CORE_UPGRADE_SKIP_NEW_BUNDLED (on by default, 0/false/no/off turns it
# off) keeps core updates from adding them; here it does the same for the
# copy: when wp-content already has any plugin or theme, the site exists and
# none of the bundled ones are copied. A new site still gets them.
if [[ ! "${CORE_UPGRADE_SKIP_NEW_BUNDLED:-}" =~ ^(0|[Ff][Aa][Ll][Ss][Ee]|[Nn][Oo]|[Oo][Ff][Ff])$ ]] \
    && [ -n "$(find wp-content/plugins wp-content/themes -mindepth 1 -maxdepth 1 ! -name index.php -print -quit 2>/dev/null)" ]; then
    echo >&2 "FrankenPress: wp-content already has plugins or themes; not copying the bundled ones (CORE_UPGRADE_SKIP_NEW_BUNDLED)"
    sourceTarArgs+=( --exclude ./wp-content/plugins --exclude ./wp-content/themes )
fi
