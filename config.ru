# Load path and gems/bundler
$LOAD_PATH << File.expand_path(File.dirname(__FILE__))
require 'tilt/erb'
require 'bundler'
require 'logger'
require 'colorize'
Bundler.require
# Local config
require "find"

$logger = Logger.new(STDOUT)

$logger.level = Logger::DEBUG
$logger.formatter = proc do |severity, datetime, progname, msg|
  date_format = datetime.strftime("%Y-%m-%d %H:%M:%S")
  if severity == "INFO"
    "[#{date_format}] #{severity}  (#{progname}): #{msg}\n".blue
  elsif severity == "WARN"
    "[#{date_format}] #{severity}  (#{progname}): #{msg}\n".orange
  else
    "[#{date_format}] #{severity} (#{progname}): #{msg}\n".red
  end
end

# Load app
require "escholApi"

fileDir = File.expand_path(File.dirname(__FILE__))
Find.find("lib") { |f|
  require f unless f.match(/\/\..+$/) || File.directory?(f) || !f.match(/\.rb$/)
}
#DB << "SET CLIENT_ENCODING TO 'UTF8';"
DB.loggers << $logger if $logger

run SinatraGraphql
