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

      handoff.release!(by: "sam")
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

    test "the handback records who made it, and it need not be who took it" do
      # Releasing is what re-enables the agent's autonomous proactive sends for
      # this pair, and on a real desk the person who ends a takeover is routinely
      # not the person who started it.
      handoff = Handoff.seize!(@subject, operator: "sam")
      handoff.release!(by: "dana@acme.test")

      handoff.reload
      assert_equal "sam", handoff.operator
      assert_equal "dana@acme.test", handoff.released_by
      assert handoff.released_at, "the handback recorded who but not when"
    end

    test "a handback with nobody's name on it is refused" do
      # Fail closed at the model, not only at the endpoint: a host calling
      # release! from its own button answers this too, and a missing answer is a
      # broken call rather than a silently unattributed row.
      assert_raises(ArgumentError) { Handoff.seize!(@subject, operator: "sam").release! }

      [ nil, "", "  " ].each do |nobody|
        handoff = Handoff.active_for(@subject) || Handoff.seize!(@subject, operator: "sam")

        assert_raises(ActiveRecord::RecordInvalid, "#{nobody.inspect} was recorded as a handback") do
          handoff.release!(by: nobody)
        end

        assert handoff.reload.active?, "a refused handback still ended the takeover"
      end
    end

    test "each seize/release cycle keeps its own pair of names" do
      # A thread can be taken and handed back repeatedly. seize! reuses only a
      # handoff that is still active, so every cycle is its own row and no cycle
      # overwrites the one before it — which is why this is two columns and not a
      # second table.
      Handoff.seize!(@subject, operator: "sam").release!(by: "dana@acme.test")
      Handoff.seize!(@subject, operator: "bill").release!(by: "sam")

      cycles = Handoff.for_scope(@subject).order(:id).map { |h| [ h.operator, h.released_by ] }
      assert_equal [ [ "sam", "dana@acme.test" ], [ "bill", "sam" ] ], cycles
    end
  end
end
