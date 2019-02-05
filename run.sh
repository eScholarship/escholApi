#!/usr/bin/env bash

set -e

[ -z $ESCHOL_DB_ADAPTER ] && [ -f config/env.sh ] && source config/env.sh
[ -z $ESCHOL_DB_ADAPTER ] && [ -f config/env-dev.sh ] && source config/env-dev.sh
bundle install --quiet --with development --path=gems --binstubs
RACK_ENV=development bundle exec rerun -d lib --pattern '**/*.rb' -- rackup -o 0.0.0.0 -p $PUMA_PORT
