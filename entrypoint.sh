#!/bin/sh
set -e
# Named volumes are root-owned on first create; hey runs as heyuser (10001).
mkdir -p /home/heyuser/.config/hey-cli
chown -R heyuser:heyuser /home/heyuser/.config
exec gosu heyuser "$@"
