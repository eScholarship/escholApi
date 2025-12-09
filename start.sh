#!/bin/sh
set -e

# Start Puma with the same options as in Procfile
exec bundle exec puma -b tcp://0.0.0.0:80 -t1:16 -w 3

