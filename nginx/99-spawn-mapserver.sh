#!/bin/sh

MAPSERVER_CMD=$(which mapserv)

echo "Checking MapServer executable... $MAPSERVER_CMD"
$MAPSERVER_CMD -v

# TODO: use envsubst to insert MS variables on default.conf
echo "Starting MapServer..."
spawn-fcgi -s /tmp/mapserver.socket -P /tmp/mapserver.pid -d /tmp -- $MAPSERVER_CMD
