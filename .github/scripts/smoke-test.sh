#!/bin/sh
# Smoke test of the release image, run by the CI on the native runner of each architecture (and locally:
# DOCKER=podman .github/scripts/smoke-test.sh <image>).
#   1. mapserv as a plain CGI (docker run, no web server): build options, WMS, OGC API, MS_MAP_PATTERN
#   2. the FastCGI server as it runs in production (arbitrary UID, read-only root filesystem), queried with
#      cgi-fcgi from another container: workers, requests, errors in the container log (FIFO), and the
#      options pinned in mapserver.conf against FastCGI parameters (a client talking FastCGI to the port
#      can set any environment variable MapServer reads per request)
set -eu

IMAGE=${1:?usage: $0 <image>}
DOCKER=${DOCKER:-docker}
NAME=mapserver-smoke-$$
CLIENT_IMAGE=docker.io/library/debian:trixie-slim

cleanup() {
    "$DOCKER" rm -f "$NAME" > /dev/null 2>&1 || :
    "$DOCKER" network rm "$NAME" > /dev/null 2>&1 || :
}
trap cleanup EXIT

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

# $1 = QUERY_STRING, $2 = PATH_INFO
cgi() {
    "$DOCKER" run --rm -e ENTRYPOINT_QUIET_LOGS=1 -e REQUEST_METHOD=GET -e SCRIPT_NAME=/mapserver \
        -e QUERY_STRING="$1" -e PATH_INFO="${2:-}" "$IMAGE" mapserv
}

echo "## build options"
version=$("$DOCKER" run --rm -e ENTRYPOINT_QUIET_LOGS=1 "$IMAGE" mapserv -v)
echo "$version"
for option in SUPPORTS=FASTCGI INPUT=ORACLESPATIAL INPUT=OGR SUPPORTS=OGCAPI_SERVER; do
    echo "$version" | grep -q "$option" || fail "mapserv -v without $option"
done
[ "$("$DOCKER" image inspect "$IMAGE" --format '{{.Config.User}}')" = 1000:0 ] || fail "image user is not 1000:0"

echo "## CGI requests"
cgi 'map=DEFAULT&SERVICE=WMS&REQUEST=GetCapabilities' | grep -q '<WMS_Capabilities' || fail "WMS GetCapabilities"
cgi 'map=DEFAULT&SERVICE=WMS&VERSION=1.3.0&REQUEST=GetMap&LAYERS=countries&STYLES=&CRS=EPSG:4326&BBOX=-90,-180,90,180&WIDTH=200&HEIGHT=100&FORMAT=image/png' \
    | head -c 100 | grep -aq '^Content-Type: image/png' || fail "WMS GetMap"
cgi 'f=json&limit=2' /DEFAULT/ogcapi/collections/countries/items | grep -q '"numberReturned":2' || fail "OGC API items"
cgi 'map=/etc/passwd&SERVICE=WMS&REQUEST=GetCapabilities' | grep -q 'fails to validate' || fail "map= outside MS_MAP_PATTERN accepted"

echo "## FastCGI server (--user 12345:0, --read-only)"
"$DOCKER" network create "$NAME" > /dev/null
"$DOCKER" run -d --name "$NAME" --network "$NAME" --user 12345:0 --read-only --tmpfs /tmp "$IMAGE" > /dev/null
sleep 3
workers=$("$DOCKER" exec "$NAME" sh -c 'n=0; for p in /proc/[0-9]*; do
    case $(tr "\0" " " < "$p/cmdline" 2> /dev/null) in /opt/geosgb/bin/mapserv*)
        [ "$(awk "/^Uid:/ { print \$2 }" "$p/status")" = 12345 ] && n=$((n + 1));;
    esac; done; echo $n')
[ "$workers" = 4 ] || fail "$workers mapserv workers running as 12345 (expected 4)"
"$DOCKER" run --rm --network "$NAME" "$CLIENT_IMAGE" sh -c "
    set -e
    export DEBIAN_FRONTEND=noninteractive
    apt-get -qq update && apt-get -qq install -y --no-install-recommends libfcgi-bin > /dev/null
    # \$1 = expected text, the rest = FastCGI parameters
    req() {
        expected=\$1
        shift
        env -i REQUEST_METHOD=GET SCRIPT_NAME=/mapserver \"\$@\" cgi-fcgi -bind -connect $NAME:8080 \
            | grep -q \"\$expected\" || { echo \"FastCGI \$*: no '\$expected'\" >&2; exit 1; }
    }
    Q='SERVICE=WMS&REQUEST=GetCapabilities'
    req '<WMS_Capabilities' QUERY_STRING=\"map=DEFAULT&\$Q\"
    # a path in map= must keep working: an invalid MS_MAP_BAD_PATTERN (escaping) rejects every path
    req '<WMS_Capabilities' QUERY_STRING=\"map=/var/lib/mapserver/data/default.map&\$Q\"
    req 'fails to validate' QUERY_STRING='map=/etc/passwd'
    # overrides sent as FastCGI parameters must not reach the pinned options
    req 'fails to validate' QUERY_STRING=\"map=/var/lib/mapserver/../../etc/passwd&\$Q\" 'MS_MAP_BAD_PATTERN=^\$' MS_MAPFILE_PATTERN=.
    req 'Filename validation failed' QUERY_STRING=\"\$Q\" MS_MAPFILE=/etc/passwd MS_MAPFILE_PATTERN=.
    req 'fails to validate' QUERY_STRING='map=DEFAULT&context=/etc/passwd&mode=map' MS_CONTEXT_PATTERN=. 'MS_CONTEXT_BAD_PATTERN=^\$'
    " || fail "FastCGI requests"
sleep 1
"$DOCKER" logs "$NAME" 2>&1 | grep -q 'msCGILoadMap().*fails to validate' || fail "MapServer error not in the container log"

echo "OK"
