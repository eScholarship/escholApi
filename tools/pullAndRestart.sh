#!/usr/bin/env bash

set -e

source config/env.sh
git pull
pkill -USR1 -f "puma.*tcp:.*$PUMA_PORT"

