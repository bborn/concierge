require "bundler/setup"

APP_RAKEFILE = File.expand_path("test/dummy/Rakefile", __dir__)
load "rails/tasks/engine.rake"

require "bundler/gem_tasks"

require "rake/testtask"

# The engine's own suite lives in test/, not in the dummy app. `rails/tasks/engine.rake`
# only exposes the dummy's tests (as app:test), so declare the engine task explicitly.
Rake::TestTask.new(:test) do |t|
  t.libs << "test"
  t.pattern = "test/**/*_test.rb"
  t.verbose = false
  t.warning = false
end

task default: :test
