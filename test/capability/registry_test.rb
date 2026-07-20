require "test_helper"

module Concierge
  module Capability
    class RegistryTest < ActiveSupport::TestCase
      setup do
        @tenant  = Tenant.create!(name: "Acme", plan: "pro")
        @subject = Concierge.config.account.build(@tenant)
        @registry = Concierge.config.capabilities
      end

      test "tools_for returns instances bound to the subject" do
        tools = @registry.tools_for(@subject)

        assert tools.all? { |t| t.subject == @subject }
        assert_includes tools.map(&:name), "recall"
      end

      test "write tools are omitted when writes are not granted" do
        read_only = @registry.tools_for(@subject, include_writes: false).map(&:name)

        assert_includes read_only, "recall"
        refute_includes read_only, "remember"
        refute_includes read_only, "set_outreach_preference"
      end

      test "with writes granted, write tools are present" do
        names = @registry.tools_for(@subject, include_writes: true).map(&:name)

        assert_includes names, "remember"
        assert_includes names, "set_outreach_preference"
      end
    end
  end
end
