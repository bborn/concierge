require "test_helper"

module Concierge
  class HandoffTest < ActiveSupport::TestCase
    setup do
      @tenant  = Tenant.create!(name: "Acme", plan: "pro", last_active_at: 1.day.ago)
      @subject = Concierge.config.account.build(@tenant)
    end

    test "seizing a thread suppresses the next proactive run; releasing restores it" do
      Concierge::Test::FakeChat.script(reply: "proactive note")

      handoff = Handoff.seize!(@subject, operator: "sam")
      suppressed = Concierge::Run.proactive(@subject, instruction: "check in")
      assert suppressed.suppressed?
      refute suppressed.ok?

      handoff.release!
      Concierge::Test::FakeChat.script(reply: "back to auto")
      restored = Concierge::Run.proactive(@subject, instruction: "check in")
      assert restored.ok?
      assert_equal "back to auto", restored.reply_text
    end

    test "reactive runs still answer during takeover" do
      Handoff.seize!(@subject, operator: "sam")
      Concierge::Test::FakeChat.script(reply: "answering the customer")

      result = Concierge::Run.reactive(@subject, "hi")
      assert result.ok?
    end

    test "seize! is idempotent" do
      a = Handoff.seize!(@subject, operator: "sam")
      b = Handoff.seize!(@subject, operator: "sam")
      assert_equal a.id, b.id
    end

    test "a takeover with nobody's name on it is refused" do
      # The customer is told "<operator> has taken this conversation over", so an
      # anonymous takeover is not renderable. The engine's endpoint refuses before
      # it reaches here; this is the same refusal for a host calling seize! itself.
      [ nil, "", "  " ].each do |nobody|
        assert_raises(ActiveRecord::RecordInvalid, "#{nobody.inspect} was recorded as an operator") do
          Handoff.seize!(@subject, operator: nobody)
        end
      end

      assert_equal 0, Handoff.count
    end
  end
end
