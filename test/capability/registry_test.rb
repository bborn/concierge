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

      # --- Registration is declarative (#4998) ---------------------------------

      test "declaring a tool twice registers it once, in its original position" do
        registry = Registry.new
        registry.register(Concierge::Tools::RecallTool,   access: :read)
        registry.register(Concierge::Tools::RememberTool, access: :write)
        registry.register(Concierge::Tools::RecallTool,   access: :read)

        assert_equal [ Concierge::Tools::RecallTool, Concierge::Tools::RememberTool ],
                     registry.entries.map(&:tool_class)
      end

      test "re-declaring a tool updates its grant instead of leaving both" do
        registry = Registry.new
        registry.register(Concierge::Tools::RecallTool, access: :read)
        registry.register(Concierge::Tools::RecallTool, access: :write)

        assert_equal [ :write ], registry.entries.map(&:access)
      end

      test "a host tool reloaded as a new class object replaces its predecessor" do
        # Host tools live in the host's app/, so Rails hands the registry a
        # brand-new Class object for the same tool after every code reload. Keyed
        # on object identity they would pile up exactly the way gem tools did —
        # and the registry would keep building the stale, unloaded class.
        first  = host_tool_named("Acme::PublishTool")
        second = host_tool_named("Acme::PublishTool")

        registry = Registry.new
        registry.register(first,  access: :read)
        registry.register(second, access: :read)

        refute_same first, second
        assert_equal [ second ], registry.entries.map(&:tool_class)
      end

      test "two anonymous tool classes are two tools" do
        # The name-based identity falls back to the class itself when there is no
        # name, so unnamed classes are never collapsed into one another.
        registry = Registry.new
        first, second = Class.new(NativeTool), Class.new(NativeTool)
        registry.register(first).register(second)

        assert_nil first.name
        assert_equal [ first, second ], registry.entries.map(&:tool_class)
      end

      private

      def host_tool_named(name)
        Class.new(NativeTool) { define_singleton_method(:name) { name } }
      end
    end
  end
end
