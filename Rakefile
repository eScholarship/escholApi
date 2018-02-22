%w{ bundler find rake/testtask}.each { |lib| require lib }
require 'sequel'

task :default => :spec

Rake::TestTask.new(:spec) do |t|
  t.test_files = FileList['spec/*_spec.rb']
end

namespace :db do
  task :environment do
    puts 'task environment'
  end

  task :connect => :environment do
    require "./config/initializers/database"
    Dir.glob('./lib/{models}/*.rb').each { |file| require file }
  end
end
