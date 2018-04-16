#!/usr/bin/env bash

# If an error occurs, stop this script
set -e

printf "== Installing local Ruby gems ==\n"
bundle install --quiet --with development --path=gems --binstubs

printf "\n== Uninstalling Ruby gems no longer used ==\n"
bundle clean

printf "\n== Installing node packages (used by graphql-schema-checker) ==\n"
yarn install --silent
