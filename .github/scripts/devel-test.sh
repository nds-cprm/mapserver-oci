#!/bin/sh
# Test of the -devel image, run by the CI on the native runner of each architecture (and locally:
# DOCKER=podman .github/scripts/devel-test.sh <image>): mapserv built with FastCGI and with the
# hardening flags of the Dockerfile (HARDENING_CFLAGS/LDFLAGS), checked with the readelf of the devel image.
# The release has the same binaries, without the debug symbols (and without readelf)
set -eu

IMAGE=${1:?usage: $0 <image>}
DOCKER=${DOCKER:-docker}

echo "## build options"
"$DOCKER" run --rm -e ENTRYPOINT_QUIET_LOGS=1 "$IMAGE" mapserv -v | grep SUPPORTS=FASTCGI

echo "## hardening (HARDENING_CFLAGS/LDFLAGS)"
"$DOCKER" run --rm -e ENTRYPOINT_QUIET_LOGS=1 "$IMAGE" sh -c '
    mapscript=$(find /opt/geosgb/venv -name "_mapscript*.so")
    [ -n "$mapscript" ] || { echo "no _mapscript module in the venv" >&2; exit 1; }
    for f in /opt/geosgb/bin/mapserv /opt/geosgb/lib/libmapserver.so $mapscript; do
        readelf -dW "$f" | grep -q BIND_NOW || { echo "no full RELRO: $f" >&2; exit 1; }
        readelf -sW --dyn-syms "$f" | grep -q __stack_chk_fail || { echo "no stack protector: $f" >&2; exit 1; }
        readelf -sW --dyn-syms "$f" | grep -q "_chk@" || { echo "no _FORTIFY_SOURCE: $f" >&2; exit 1; }
        echo "ok: $f"
    done'

echo "## Python MapScript"
"$DOCKER" run --rm -e ENTRYPOINT_QUIET_LOGS=1 "$IMAGE" \
    python -c "import mapscript; print('mapscript', mapscript.MS_VERSION)"

echo "OK"
