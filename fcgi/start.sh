#!/bin/sh

MAPSERVER_CMD=$(which mapserv)

echo "Checking MapServer executable... $MAPSERVER_CMD"
$MAPSERVER_CMD -v

# TODO: use envsubst to insert MS variables on default.conf
echo "Starting MapServer as FastCGI..."
spawn-fcgi -p 8080 -d /var/lib/mapserver -n -- $MAPSERVER_CMD
