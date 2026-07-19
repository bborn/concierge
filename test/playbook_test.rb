require "test_helper"

class PlaybookTest < ActiveSupport::TestCase
  test "exposes host-declared product knowledge" do
    playbook = Concierge.config.playbook

    assert_equal "Acme helps teams publish changelogs.", playbook.product_brief
    assert_equal %i[brand creator], playbook.account_types
    assert_includes playbook.engagement_signals.keys, :has_paid_plan
  end

  test "persona returns the configured persona" do
    persona = Concierge.config.playbook.persona!

    assert_equal "Kit", persona.name
    assert_equal "warm, concise, never pushy", persona.voice
  end

  test "persona! raises when the host configured none" do
    playbook = Concierge::Playbook.new
    playbook.product_brief "no persona here"

    assert_nil playbook.persona
    assert_raises(Concierge::PersonaNotConfigured) { playbook.persona! }
  end

  test "engagement signals preserve registration order" do
    assert_equal %i[has_paid_plan user_count days_since_active],
                 Concierge.config.playbook.engagement_signals.keys
  end
end
