#\ --quiet
# Above line disables rackup's default logger, which is remarkably hard to turn off

# Load path and gems/bundler
$LOAD_PATH << File.expand_path(File.dirname(__FILE__))
require 'tilt/erb'
require 'bundler'
require 'logger'
require 'colorize'
Bundler.require

require_relative "./lib/sharedTypes.rb"
require_relative "./lib/database.rb"
require_relative "./lib/models.rb"
require_relative "./lib/xmlGen.rb"
require_relative "./lib/escholAPI.rb"

# Log database queries while debugging
DB.loggers << Logger.new(STDOUT)

# Go for it
run EscholAPI
