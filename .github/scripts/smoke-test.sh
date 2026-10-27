#!/bin/sh
# Smoke test of the release image, run by the CI on the native runner of each architecture (and locally:
# DOCKER=podman .github/scripts/smoke-test.sh <image>).
#   1. mapserv as a plain CGI (docker run, no web server): build options, WMS, OGC API, MS_MAP_PATTERN
#   2. the FastCGI server as it runs in production (arbitrary UID, read-only root filesystem) behind nginx
#      with the configuration of examples/nginx: healthcheck (and that it logs nothing), workers, WMS and
#      OGC API through nginx, errors in the container log (FIFO)
#   3. the options pinned in mapserver.conf against FastCGI parameters, with the cgi-fcgi of the image (a
#      client talking FastCGI to the port can set any environment variable MapServer reads per request)
set -eu
# byte-wise grep on binary responses (PNG), also with the BSD tools of macOS
export LC_ALL=C

IMAGE=${1:?usage: $0 <image>}
DOCKER=${DOCKER:-docker}
NAME=mapserver-smoke-$$
NGINX_IMAGE=docker.io/nginxinc/nginx-unprivileged:1.30-alpine
NGINX_CONF=$(cd "$(dirname "$0")/../../examples/nginx/conf/nginx" && pwd)/nginx.conf

cleanup() {
    "$DOCKER" rm -f "$NAME" "$NAME-nginx" > /dev/null 2>&1 || :
    "$DOCKER" network rm "$NAME" > /dev/null 2>&1 || :
}
trap cleanup EXIT

fail() {
    echo "FAIL: $*" >&2
    "$DOCKER" logs "$NAME" 2>&1 | tail -20 >&2 || :
    exit 1
}

# $1 = QUERY_STRING, $2 = PATH_INFO
cgi() {
    "$DOCKER" run --rm -e ENTRYPOINT_QUIET_LOGS=1 -e REQUEST_METHOD=GET -e SCRIPT_NAME=/mapserver \
        -e QUERY_STRING="$1" -e PATH_INFO="${2:-}" "$IMAGE" mapserv
}

# GET through nginx; prints the body
get() {
    "$DOCKER" exec "$NAME-nginx" wget -q -O - "http://127.0.0.1:8080$1"
}

# FastCGI request straight to the port, from inside the container: $1 = expected text, the rest = FastCGI
# parameters
fcgi() {
    expected=$1
    shift
    "$DOCKER" exec "$NAME" env -i REQUEST_METHOD=GET SCRIPT_NAME=/mapserver "$@" \
        cgi-fcgi -bind -connect 127.0.0.1:8080 | grep -aq "$expected" || fail "FastCGI $*: no '$expected'"
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

echo "## FastCGI server (--user 12345:0, --read-only) behind nginx"
"$DOCKER" network create "$NAME" > /dev/null
# network alias mapserver: the upstream of examples/nginx/conf/nginx/nginx.conf
"$DOCKER" run -d --name "$NAME" --network "$NAME" --network-alias mapserver \
    --user 12345:0 --read-only --tmpfs /tmp "$IMAGE" > /dev/null
healthy=
for _ in $(seq 15); do
    if "$DOCKER" exec "$NAME" healthcheck; then
        healthy=yes
        break
    fi
    sleep 2
done
[ -n "$healthy" ] || fail "healthcheck did not pass within 30 s"
lines=$("$DOCKER" logs "$NAME" 2>&1 | wc -l)
"$DOCKER" exec "$NAME" healthcheck || fail "healthcheck"
sleep 1
[ "$("$DOCKER" logs "$NAME" 2>&1 | wc -l)" = "$lines" ] || fail "the healthcheck request wrote to the log"
workers=$("$DOCKER" exec "$NAME" sh -c 'n=0; for p in /proc/[0-9]*; do
    case $(tr "\0" " " < "$p/cmdline" 2> /dev/null) in /opt/geosgb/bin/mapserv*)
        [ "$(awk "/^Uid:/ { print \$2 }" "$p/status")" = 12345 ] && n=$((n + 1));;
    esac; done; echo $n')
[ "$workers" = 4 ] || fail "$workers mapserv workers running as 12345 (expected 4)"

"$DOCKER" run -d --name "$NAME-nginx" --network "$NAME" --read-only --tmpfs /tmp \
    -v "$NGINX_CONF:/etc/nginx/conf.d/default.conf:ro" "$NGINX_IMAGE" > /dev/null
# nginx is up once it answers: 404 outside /mapserver (instead of "Connection refused")
up=
for _ in $(seq 15); do
    if "$DOCKER" exec "$NAME-nginx" wget -q -O /dev/null http://127.0.0.1:8080/ 2>&1 | grep -q 404; then
        up=yes
        break
    fi
    sleep 1
done
[ -n "$up" ] || fail "nginx did not start within 15 s"
get '/mapserver?map=DEFAULT&SERVICE=WMS&REQUEST=GetCapabilities' | grep -q '<WMS_Capabilities' \
    || fail "WMS GetCapabilities through nginx"
get '/mapserver?map=DEFAULT&SERVICE=WMS&VERSION=1.3.0&REQUEST=GetMap&LAYERS=countries&STYLES=&CRS=EPSG:4326&BBOX=-90,-180,90,180&WIDTH=200&HEIGHT=100&FORMAT=image/png' \
    | head -c 8 | grep -aq 'PNG' || fail "WMS GetMap through nginx"
# PATH_INFO split by nginx (fastcgi_split_path_info)
get '/mapserver/DEFAULT/ogcapi/collections/countries/items?f=json&limit=2' | grep -q '"numberReturned":2' \
    || fail "OGC API items through nginx"
# only /mapserver and /mapserver/... go to MapServer
"$DOCKER" exec "$NAME-nginx" wget -q -O /dev/null 'http://127.0.0.1:8080/mapserverfoo?map=DEFAULT' 2>&1 | grep -q 404 \
    || fail "/mapserverfoo not answered with 404 by nginx"
get '/mapserver?map=/etc/passwd' | grep -q 'fails to validate' || fail "map= outside MS_MAP_PATTERN accepted"
sleep 1
"$DOCKER" logs "$NAME" 2>&1 | grep -q 'msCGILoadMap().*fails to validate' || fail "MapServer error not in the container log"

echo "## options pinned against FastCGI parameters"
Q='SERVICE=WMS&REQUEST=GetCapabilities'
# a path in map= must keep working: an invalid MS_MAP_BAD_PATTERN (escaping) rejects every path
fcgi '<WMS_Capabilities' QUERY_STRING="map=/var/lib/mapserver/data/default.map&$Q"
fcgi 'fails to validate' QUERY_STRING="map=/var/lib/mapserver/../../etc/passwd&$Q" 'MS_MAP_BAD_PATTERN=^$' MS_MAPFILE_PATTERN=.
fcgi 'Filename validation failed' QUERY_STRING="$Q" MS_MAPFILE=/etc/passwd MS_MAPFILE_PATTERN=.
fcgi 'fails to validate' QUERY_STRING='map=DEFAULT&context=/etc/passwd&mode=map' MS_CONTEXT_PATTERN=. 'MS_CONTEXT_BAD_PATTERN=^$'

echo "OK"
