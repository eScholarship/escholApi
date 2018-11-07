#\ --quiet
# Above line disables rackup's default logger, which is remarkably hard to turn off

# Load path and gems/bundler
$LOAD_PATH << File.expand_path(File.dirname(__FILE__))
require 'tilt/erb'
require 'bundler'
require 'logger'
require 'colorize'
Bundler.require
# Local config
require "find"

# Load app
require "escholApi"

# Include every Ruby file in the 'lib' directory
fileDir = File.expand_path(File.dirname(__FILE__))
Find.find("lib") { |f|
  require f unless f.match(/\/\..+$/) || File.directory?(f) || !f.match(/\.rb$/)
}

# Log database queries for now
DB.loggers << Logger.new(STDOUT)

# Go for it
run EscholAPI
