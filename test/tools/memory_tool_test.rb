require "test_helper"

module Concierge
  module Tools
    class MemoryToolTest < ActiveSupport::TestCase
      setup do
        @tenant  = Tenant.create!(name: "Acme", plan: "pro")
        @other   = Tenant.create!(name: "Beta", plan: "free")
        @subject = Concierge.config.account.build(@tenant)
      end

      test "remember writes a memory for the current subject only" do
        tool = RememberTool.new(subject: @subject)
        assert_equal({ ok: true }, tool.execute(body: "likes weekly digests", category: "preference"))

        assert_equal 1, Memory.for_subject(@subject).count
        assert_equal 0, Memory.for_subject(Concierge.config.account.build(@other)).count
      end

      test "recall reads back what remember wrote, scoped to the subject" do
        RememberTool.new(subject: @subject).execute(body: "loves changelogs")
        RememberTool.new(subject: Concierge.config.account.build(@other)).execute(body: "beta secret")

        results = RecallTool.new(subject: @subject).execute(query: "changelog")
        assert_equal [ "loves changelogs" ], results
      end

      test "forget retires a note and reports missing ids" do
        row = Memory.create!(subject_type: "account", subject_id: @tenant.id.to_s, body: "temp")
        tool = ForgetTool.new(subject: @subject)

        assert_equal({ ok: true }, tool.execute(id: row.id))
        refute row.reload.active

        missing = tool.execute(id: 999_999)
        assert missing[:error]
      end

      test "a tool cannot reach another account's rows" do
        # A note that belongs to @other must be invisible/untouchable from @subject.
        row = Memory.create!(subject_type: "account", subject_id: @other.id.to_s, body: "beta note")

        assert_equal({ error: "no note ##{row.id} for this account" },
                     ForgetTool.new(subject: @subject).execute(id: row.id))
        assert row.reload.active, "cross-account row must be untouched"
      end

      test "set_outreach_preference persists frequency" do
        tool = SetOutreachPreferenceTool.new(subject: @subject)
        assert_equal({ ok: true, frequency: "less" }, tool.execute(frequency: "less"))

        assert_equal "less", OutreachPreference.for(@subject).frequency
      end

      test "set_outreach_preference rejects an unknown frequency" do
        result = SetOutreachPreferenceTool.new(subject: @subject).execute(frequency: "sometimes")
        assert result[:error]
      end

      test "a raising tool reports the error instead of crashing the run" do
        tool = RememberTool.new(subject: @subject)
        tool.define_singleton_method(:perform) { |**| raise "boom" }

        assert_equal({ error: "boom" }, tool.execute(body: "anything"))
      end

      test "routine tool creates an account-scoped routine (Phase 7)" do
        result = RoutineTool.new(subject: @subject).execute(
          action: "create", schedule: "0 9 * * 1", instruction: "weekly report"
        )
        assert result[:ok]
        assert_equal 1, Concierge::Routine.for_subject(@subject).count
      end
    end
  end
end
