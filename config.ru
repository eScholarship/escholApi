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

require_relative "./lib/sharedTypes.rb"
require_relative "./lib/appBase.rb"
require_relative "./lib/database.rb"
require_relative "./lib/models.rb"
require_relative "./lib/xmlGen.rb"
require_relative "./lib/access/accessAPI.rb"
require_relative "./lib/submit/submitAPI.rb"

# Log database queries while debugging
DB.loggers << Logger.new(STDOUT)

# Go for it
case ENV['API']
  when 'access'; run AccessAPI
  when 'submit'; run SubmitAPI
  else;          raise("Invalid value of API env var: #{ENV['API'].inspect}")
end
