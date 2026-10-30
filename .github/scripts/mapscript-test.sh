#!/bin/sh
# Test of the release-mapscript image (-py<X.Y>-mapscript tag), run by the CI after smoke-test.sh, which covers its
# FastCGI server (the same as the release), and locally: DOCKER=podman .github/scripts/mapscript-test.sh <image>.
# Python MapScript as it runs in derived images: arbitrary UID, read-only root filesystem
set -eu

IMAGE=${1:?usage: $0 <image>}
DOCKER=${DOCKER:-docker}

run() {
    "$DOCKER" run --rm -e ENTRYPOINT_QUIET_LOGS=1 --user 12345:0 --read-only --tmpfs /tmp "$IMAGE" "$@"
}

echo "## venv and constraints"
# constraints.txt lists every package of the venv (pip list --format=freeze), mapscript included
run sh -c '
    pip check
    pip list --format=freeze | diff - /opt/geosgb/share/mapserver/constraints.txt \
        || { echo "constraints.txt differs from the venv" >&2; exit 1; }
    grep -qx "mapscript==$(python -c "import mapscript; print(mapscript.MS_VERSION)")" \
        /opt/geosgb/share/mapserver/constraints.txt \
        || { echo "mapscript version missing from constraints.txt" >&2; exit 1; }'

echo "## pip cache (docker/30-xdg-cache.sh)"
# HOME is read-only: XDG_CACHE_HOME in /tmp, used by pip without the "not writable" warning
out=$(run sh -c 'echo "XDG_CACHE_HOME=$XDG_CACHE_HOME"; pip cache dir' 2>&1)
echo "$out"
echo "$out" | grep -q '^XDG_CACHE_HOME=/tmp/cache\.' || { echo "XDG_CACHE_HOME not in /tmp" >&2; exit 1; }
if echo "$out" | grep -q 'WARNING'; then echo "pip warns about its cache" >&2; exit 1; fi

echo "## MapScript renders the sample mapfile"
run python -c '
import mapscript
m = mapscript.mapObj("/var/lib/mapserver/data/default.map")
data = m.draw().getBytes()
assert data[:8] == b"\x89PNG\r\n\x1a\n", data[:8]
print("mapscript", mapscript.MS_VERSION, m.name, len(data), "bytes")
'

echo "OK"
