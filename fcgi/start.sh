#!/bin/sh
set -e

MAPSERVER_CMD=$(command -v mapserv)

echo "Checking MapServer executable... $MAPSERVER_CMD"
$MAPSERVER_CMD -v

# spawn-fcgi binds the socket and execs multiwatch, which keeps MAPSERVER_WORKERS
# mapserv processes alive (restarting crashed ones) and forwards signals to them
echo "Starting MapServer as FastCGI on port $MAPSERVER_FCGI_PORT with $MAPSERVER_WORKERS workers..."
exec spawn-fcgi -n -a 0.0.0.0 -p "$MAPSERVER_FCGI_PORT" -d /var/lib/mapserver -- \
    /usr/bin/multiwatch -f "$MAPSERVER_WORKERS" -- "$MAPSERVER_CMD"
