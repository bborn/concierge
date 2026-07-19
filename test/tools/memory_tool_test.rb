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

        assert_equal "less", OutreachPreference.for_subject(@subject).frequency
      end

      test "set_outreach_preference rejects an unknown frequency" do
        result = SetOutreachPreferenceTool.new(subject: @subject).execute(frequency: "sometimes")
        assert result[:error]
      end

      test "routine tool is a registered but inert seam until Phase 7" do
        assert_raises(NotImplementedError) do
          RoutineTool.new(subject: @subject).execute(action: "create")
        end
      end
    end
  end
end
