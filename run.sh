#!/usr/bin/env bash

RACK_ENV=development bundle exec rerun -d lib --pattern '**/*.rb' -- rackup -o 0.0.0.0 -p 18900
