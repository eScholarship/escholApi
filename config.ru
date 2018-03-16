# Load path and gems/bundler
$LOAD_PATH << File.expand_path(File.dirname(__FILE__))
require 'tilt/erb'
require 'bundler'
require 'logger'
require 'colorize'
Bundler.require
# Local config
require "find"

# Make puts thread-safe, and flush after every puts.
$stdoutMutex = Mutex.new
$workerNum = 0
$workerPrefix = ""
$nextThreadNum = 0
def puts(str)
  $stdoutMutex.synchronize {
    if !Thread.current[:number]
      allNums = Set.new
      Thread.list.each { |t| allNums << t[:number] }
      num = 0
      while allNums.include?(num)
        num += 1
      end
      Thread.current[:number] = num
    end
    STDOUT.puts "[#{$workerPrefix}#{Thread.current[:number]}] #{str}"
    STDOUT.flush
  }
end

logger = Logger.new(STDOUT)

logger.level = Logger::DEBUG
logger.formatter = proc do |severity, datetime, progname, msg|
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
puts "fileDir=#{fileDir}"
puts "cwd=#{Dir.getwd}"
Find.find(fileDir) do |path|
  if path != fileDir && File.directory?(path)
    puts "  subdir=#{path}"
    Find.prune
  end
end
%w{config/initializers lib}.each do |load_path|
  puts "Searching #{load_path.inspect}"
  puts "  exists=#{File.exists?(load_path).inspect}"
  Find.find(load_path) { |f|
    require f unless f.match(/\/\..+$/) || File.directory?(f)
  }
end
#DB << "SET CLIENT_ENCODING TO 'UTF8';"
DB.loggers << logger if logger

run SinatraGraphql
