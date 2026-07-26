require "test_helper"

class PlaybookTest < ActiveSupport::TestCase
  test "exposes host-declared product knowledge" do
    playbook = Concierge.config.playbook

    assert_equal "Acme helps teams publish changelogs.", playbook.product_brief
    assert_equal %i[brand creator], playbook.account_types
    assert_includes playbook.engagement_signals.keys, :has_paid_plan
  end

  test "persona returns the configured persona" do
    persona = Concierge.config.playbook.persona

    assert_equal "Kit", persona.name
    assert_equal "warm, concise, never pushy", persona.voice
    assert Concierge.config.playbook.persona_configured?
  end

  test "an unset persona falls back to the neutral default voice" do
    playbook = Concierge::Playbook.new
    playbook.product_brief "no persona here"

    refute playbook.persona_configured?
    assert_nil playbook.persona.name
    assert_equal Concierge::Playbook::DEFAULT_PERSONA.voice, playbook.persona.voice
  end

  test "an account type declared twice is declared once" do
    # Concierge::Agent#playbook memoizes, and a host's config block re-runs on
    # every Rails code reload — so a concatenating list grows a copy per reload.
    playbook = Concierge::Playbook.new
    playbook.account_types :brand, :creator
    playbook.account_types :brand, :creator
    playbook.account_types :agency

    assert_equal %i[brand creator agency], playbook.account_types
  end

  test "engagement signals preserve registration order" do
    assert_equal %i[has_paid_plan user_count days_since_active],
                 Concierge.config.playbook.engagement_signals.keys
  end
end
