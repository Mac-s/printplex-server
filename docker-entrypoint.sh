#!/bin/sh
set -e

# linuxserver.io-style PUID/PGID: align the in-container `printplex` user with
# whatever host user already owns the bind-mounted /media and /data
# directories, so the server can read/write them without any manual chown or
# chmod on the host. Defaults to 1000:1000 (the first regular user on most
# Debian/Ubuntu installs) when unset.
PUID="${PUID:-1000}"
PGID="${PGID:-1000}"

# Only /app (baked into the image, tiny) gets re-chowned here — never the
# mounted volumes, which are expected to already belong to that host user/group.
groupmod -o -g "$PGID" printplex
usermod -o -u "$PUID" printplex
chown -R printplex:printplex /app

exec gosu printplex "$@"
