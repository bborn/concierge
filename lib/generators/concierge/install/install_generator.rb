require "rails/generators"
require "rails/generators/migration"

module Concierge
  module Generators
    # `bin/rails generate concierge:install` — brings Concierge into a host app:
    # copies the engine migrations, mounts the engine, writes a configuration
    # initializer skeleton, and points the host at the RubyLLM install if it
    # isn't present yet.
    class InstallGenerator < Rails::Generators::Base
      include Rails::Generators::Migration

      source_root File.expand_path("templates", __dir__)

      def self.next_migration_number(dirname)
        next_migration_number = current_migration_number(dirname) + 1
        ActiveRecord::Migration.next_migration_number(next_migration_number)
      end

      def copy_migrations
        rake "concierge:install:migrations"
      end

      def mount_engine
        route %(mount Concierge::Engine => "/concierge")
      end

      def create_initializer
        template "concierge.rb", "config/initializers/concierge.rb"
      end

      def check_ruby_llm
        return if File.exist?(File.join(destination_root, "app/models/chat.rb"))

        say <<~MSG, :yellow
          Concierge builds on RubyLLM's Chat/Message/ToolCall models but none were found.
          Run the RubyLLM install first:

              bin/rails generate ruby_llm:install
              bin/rails db:migrate
        MSG
      end

      def done
        say "Concierge installed. Edit config/initializers/concierge.rb, then run bin/rails db:migrate.", :green
      end
    end
  end
end
