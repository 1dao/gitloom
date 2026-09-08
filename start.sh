#!/bin/sh
# Start gitloom. Config comes from gitloom.cfg (and gitloom.local.cfg, which is
# loaded first and wins); override any key on the command line, e.g.
#   ./start.sh LISTEN_PORT=9000 ANON_READ=0
cd "$(dirname "$0")" || exit 1
exec bin/xnet main.lua AUTH_ALLOW_REGISTRATION=1 DAEMON=1 SERVER_NAME=gitloom "$@"
