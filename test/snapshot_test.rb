require "test_helper"

class SnapshotTest < ActiveSupport::TestCase
  setup do
    @tenant = Tenant.create!(name: "Acme", plan: "pro", last_active_at: 3.days.ago)
    @tenant.users.create!(email: "a@acme.test")
    @tenant.users.create!(email: "b@acme.test")
    @subject = Concierge.config.account.build(@tenant)
  end

  test "evaluates each engagement signal against the subject" do
    h = Concierge::Snapshot.for(@subject).to_h

    assert_equal true, h[:has_paid_plan]
    assert_equal 2, h[:user_count]
    assert_equal 3, h[:days_since_active]
  end

  test "signal values appear in registration order" do
    assert_equal %i[has_paid_plan user_count days_since_active],
                 Concierge::Snapshot.for(@subject).to_h.keys
  end

  test "is deterministic across two calls with unchanged data" do
    travel_to Time.current do
      a = Concierge::Snapshot.for(@subject).to_h
      b = Concierge::Snapshot.for(@subject).to_h
      assert_equal a, b
    end
  end

  test "to_prompt renders a stable, readable block" do
    travel_to Time.current do
      prompt = Concierge::Snapshot.for(@subject).to_prompt
      assert_includes prompt, "Account state:"
      assert_includes prompt, "- has_paid_plan: yes"
      assert_includes prompt, "- user_count: 2"
    end
  end

  test "a raising signal is captured inline and never crashes the snapshot" do
    playbook = Concierge::Playbook.new
    playbook.engagement_signal(:boom) { |_s| raise "kaboom" }

    h = Concierge::Snapshot.for(@subject, playbook: playbook).to_h

    assert_match(/<error: kaboom>/, h[:boom])
  end

  test "an unset persona falls back to a neutral default voice" do
    playbook = Concierge::Playbook.new
    refute playbook.persona_configured?
    assert_equal Concierge::Playbook::DEFAULT_PERSONA.voice, playbook.persona.voice
  end
end
