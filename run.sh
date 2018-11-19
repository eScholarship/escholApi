#!/usr/bin/env bash

set -e

bundle install --quiet --with development --path=gems --binstubs
RACK_ENV=development bundle exec rerun -d lib --pattern '**/*.rb' -- rackup -o 0.0.0.0 -p 18900
