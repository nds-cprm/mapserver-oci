# Sourced by /docker-entrypoint.sh after 20-mapserver-home.sh (release-mapscript only). HOME
# (/var/lib/mapserver) is read-only, so pip and other Python tools that cache in ~/.cache (XDG_CACHE_HOME)
# would warn or fail: point XDG_CACHE_HOME to a new directory of its own in /tmp (mktemp: 0700, fails if the
# name exists), never a fixed path, which could have been planted beforehand. An XDG_CACHE_HOME of your own
# (-e XDG_CACHE_HOME=...) or a usable ~/.cache (root) is kept. Not applied to docker exec, which does not
# go through the entrypoint.
if [ -z "${XDG_CACHE_HOME:-}" ]; then
    xdg_cache=${HOME:-/}/.cache
    # ~/.cache is usable if it is a writable directory, or missing in a writable HOME
    if ! { [ -d "$xdg_cache" ] && [ -w "$xdg_cache" ]; } && ! { [ ! -e "$xdg_cache" ] && [ -w "${HOME:-/}" ]; }; then
        # a /tmp that is not writable only leaves the cache off: it does not stop the container start
        if xdg_cache=$(mktemp -d "${TMPDIR:-/tmp}/cache.XXXXXX" 2> /dev/null); then
            export XDG_CACHE_HOME="$xdg_cache"
        fi
    fi
    unset xdg_cache
fi
