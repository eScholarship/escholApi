#!/usr/bin/env bash

RACK_ENV=development bundle exec rerun -d lib --pattern '**/*.rb' -- rackup -p 3000
