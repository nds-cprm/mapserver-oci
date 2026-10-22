#!/bin/sh
set -e

MAPSERVER_CMD=$(command -v mapserv)

# Without MS_ERRORFILE, send MapServer errors to the container log (docker logs). "stderr" would be the
# FastCGI stderr stream (web server log) and /dev/stderr can't be opened by non-root users, so the
# workers write to a FIFO that a background reader copies to this process' stderr.
if [ -z "${MS_ERRORFILE:-}" ]; then
    LOG_FIFO=/tmp/mapserver-errors.fifo
    rm -f "$LOG_FIFO"
    mkfifo -m 600 "$LOG_FIFO"
    # keep the FIFO open read-write on fd 3, inherited by spawn-fcgi/multiwatch/workers: there is always
    # a reader, so opening it never blocks (a worker respawned after the reader died would hang in fopen)
    # and the reader below never sees EOF
    exec 3<> "$LOG_FIFO"
    # reader, restarted if it dies (until then messages wait in the 64 KB pipe buffer);
    # "|| :" keeps set -e from ending the loop when cat is killed
    ( while :; do cat <&3 >&2 || :; sleep 1; done ) &
    export MS_ERRORFILE="$LOG_FIFO"
fi

echo "Checking MapServer executable... $MAPSERVER_CMD"
$MAPSERVER_CMD -v

# spawn-fcgi binds the socket and execs multiwatch, which keeps MAPSERVER_WORKERS
# mapserv processes alive (restarting crashed ones) and forwards signals to them
echo "Starting MapServer as FastCGI on port $MAPSERVER_FCGI_PORT with $MAPSERVER_WORKERS workers..."
exec spawn-fcgi -n -a 0.0.0.0 -p "$MAPSERVER_FCGI_PORT" -d /var/lib/mapserver -- \
    /usr/bin/multiwatch -f "$MAPSERVER_WORKERS" -- "$MAPSERVER_CMD"
