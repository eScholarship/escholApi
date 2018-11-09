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

# Include every Ruby file in the 'lib' directory
fileDir = File.expand_path(File.dirname(__FILE__))
Find.find("lib").sort { |a,b| a =~ /shared/ ? -1 : b =~ /shared/ ? 1 : a <=> b }.each { |f|
  require f unless f.match(/\/\..+$/) || File.directory?(f) || !f.match(/\.rb$/)
}

# Log database queries while debugging
DB.loggers << Logger.new(STDOUT)

# Go for it
case ENV['API']
  when 'access'; run AccessAPI
  when 'submit'; run SubmitAPI
  else;          raise("Invalid value of API env var: #{ENV['API'].inspect}")
end
