# Sourced by /docker-entrypoint.sh after 10-enable-nss-wrapper.sh (base image), which replaces a HOME
# that is not writable with /tmp. /var/lib/mapserver is read-only on purpose (mapfiles are loaded from it,
# MS_MAP_PATTERN), so it is set back as HOME for every user, in the environment and in the nss_wrapper
# passwd entry. A HOME of your own (-e HOME=...) is kept if it is writable at startup (checked by the base
# script) and is not /tmp.
MAPSERVER_HOME=/var/lib/mapserver

if [ "${HOME:-}" = /tmp ]; then
    export HOME="$MAPSERVER_HOME"
    # virtual user written by 10-enable-nss-wrapper.sh (USER_NAME is validated there): 6th field = home
    if [ -n "${NSS_WRAPPER_PASSWD:-}" ]; then
        sed -i "s|^\(${USER_NAME}:x:$(id -u):[^:]*:[^:]*:\)[^:]*:|\1${MAPSERVER_HOME}:|" "$NSS_WRAPPER_PASSWD"
    fi
fi
