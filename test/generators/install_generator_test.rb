require "test_helper"
require "rails/generators"
require "generators/concierge/install/install_generator"

module Concierge
  module Generators
    class InstallGeneratorTest < Rails::Generators::TestCase
      tests Concierge::Generators::InstallGenerator
      destination File.expand_path("../../tmp/generator", __dir__)
      setup :prepare_destination

      test "writes a configuration initializer" do
        # The migration-copy (rake) and engine-mount (host routes) steps need a
        # full host app; no-op them and exercise the initializer step directly.
        gen = generator
        def gen.copy_migrations = nil
        def gen.mount_engine = nil
        gen.invoke_all

        assert_file "config/initializers/concierge.rb" do |content|
          assert_match(/Concierge\.configure/, content)
          assert_match(/config\.account do/, content)
          assert_match(/config\.capabilities do/, content)
        end
      end

      test "the initializer template is valid Ruby" do
        template = File.expand_path("../../lib/generators/concierge/install/templates/concierge.rb", __dir__)
        assert_nothing_raised { RubyVM::InstructionSequence.compile(File.read(template)) }
      end
    end
  end
end
