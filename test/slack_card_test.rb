require "test_helper"

module Concierge
  # The card a human decides from (§2.6): Approve / Reject / Correct, the gate, the
  # provenance, and — once decided — who, when and what instead of buttons.
  class SlackCardTest < ActiveSupport::TestCase
    setup do
      Concierge::Test.configure_agents!
      @tenant  = Tenant.create!(name: "Acme", plan: "pro")
      @subject = Concierge.config.account.build(@tenant)
      @scope   = Concierge::Scope.new(Concierge.config.agent(:billing), @subject)
    end

    test "an awaiting proposal offers approve, correct and reject" do
      card = Concierge::Slack::Card.new(proposal)

      actions = card.blocks.find { |block| block[:type] == "actions" }
      assert_equal [ Concierge::Slack::Card::APPROVE, Concierge::Slack::Card::CORRECT,
                     Concierge::Slack::Card::REJECT ],
                   actions[:elements].map { |element| element[:action_id] }
      assert_equal %w[primary danger], actions[:elements].filter_map { |e| e[:style] }
    end

    test "every button carries the proposal id, so a click is unambiguous" do
      row  = proposal
      card = Concierge::Slack::Card.new(row)

      actions = card.blocks.find { |block| block[:type] == "actions" }
      assert_equal [ row.id.to_s ] * 3, actions[:elements].map { |element| element[:value] }
    end

    test "the card states which gate applies, because approving does not always execute" do
      approval  = Concierge::Slack::Card.new(proposal(action_class: "record.plan_change"))
      execution = Concierge::Slack::Card.new(proposal(action_class: "money.refund",
                                                     gate: "human_execution",
                                                     key: "refund-1"))

      assert_match "approving executes it", JSON.generate(approval.blocks)
      assert_match "approve it, then do it yourself", JSON.generate(execution.blocks)
    end

    test "a card names the rules the agent said steered the draft" do
      row = proposal(rule_ids_applied: [ 7, 9 ])

      assert_match(/Rules the agent says it applied: #7, #9/, JSON.generate(Concierge::Slack::Card.new(row).blocks))
    end

    test "a card says the record is the admin queue, not the message" do
      assert_match "/concierge/admin/proposals", JSON.generate(Concierge::Slack::Card.new(proposal).blocks)
    end

    test "a decided card has no buttons and says who decided it" do
      row = proposal
      Concierge::ApprovalIntake.reject(row, by: "sam@acme.test", reason: "wrong account")

      blocks = Concierge::Slack::Card.new(row.reload).blocks
      assert_nil blocks.find { |block| block[:type] == "actions" },
                 "a decided card still offered a button that would now be refused"
      rendered = JSON.generate(blocks)
      assert_match "Rejected* by sam@acme.test", rendered
      assert_match "wrong account", rendered
    end

    test "an approved-but-unperformed card says so rather than reading as a success" do
      # The property step 3 established on the admin queue: approved is not done.
      row = proposal(action_class: "money.refund", gate: "human_execution", key: "refund-2")
      Concierge::ApprovalIntake.approve(row, by: "sam@acme.test")

      rendered = JSON.generate(Concierge::Slack::Card.new(row.reload).decided_blocks)
      assert_match "Approved*", rendered
      assert_match "the engine does not perform this one; you do", rendered
      refute_match "Executed", rendered
    end

    test "a draft that tried to ping a channel is neutralized and flagged" do
      row = proposal(action_class: "message.outreach",
                     payload: { "body" => "<!channel> everyone look at this" },
                     key: "shout-1")

      rendered = JSON.generate(Concierge::Slack::Card.new(row).blocks)
      refute_match "<!channel>", rendered
      assert_match "@channel", rendered
      assert_match "tried to notify a whole channel", rendered
    end

    test "the reject modal requires a reason and carries the proposal in its metadata" do
      row  = proposal
      view = Concierge::Slack::Card.new(row).reject_modal({ "proposal_id" => row.id,
                                                            "channel" => "C1", "ts" => "1.1" })

      assert_equal Concierge::Slack::Card::REJECT_MODAL, view[:callback_id]
      assert_equal row.id, JSON.parse(view[:private_metadata])["proposal_id"]

      reason = view[:blocks].find { |block| block[:block_id] == Concierge::Slack::Card::REASON_BLOCK }
      assert reason, "the reject modal had no reason field"
      refute reason[:optional], "a rejection reason must not be optional"
    end

    test "the correct modal offers one input per proposed argument and nothing more" do
      row  = proposal(action_class: "record.plan_change",
                      payload: { "from" => "pro", "to" => "enterprise" }, key: "plan-1")
      view = Concierge::Slack::Card.new(row).correct_modal({ "proposal_id" => row.id })

      offered = view[:blocks].filter_map { |block| block[:block_id] }
                             .grep(/\A#{Concierge::Slack::Card::PAYLOAD_PREFIX}/)
      assert_equal [ "#{Concierge::Slack::Card::PAYLOAD_PREFIX}from",
                     "#{Concierge::Slack::Card::PAYLOAD_PREFIX}to" ], offered
    end

    test "the correct modal opens the rule write path, optionally" do
      view = Concierge::Slack::Card.new(proposal).correct_modal({})

      rule = view[:blocks].find { |block| block[:block_id] == Concierge::Slack::Card::RULE_BLOCK }
      assert rule, "correcting a draft did not offer to write a rule"
      assert rule[:optional], "a correction must not force the human to write a rule"
      assert_match "never an active one", rule[:hint][:text]
    end

    test "a proposal whose arguments are all structured offers no Correct button" do
      # There is no honest single-line editor for a nested payload, and guessing at
      # one is how a correction quietly drops half of it.
      row  = proposal(action_class: "record.update",
                      payload: { "changes" => { "plan" => "enterprise" } }, key: "nested-1")
      card = Concierge::Slack::Card.new(row)

      actions = card.blocks.find { |block| block[:type] == "actions" }
      refute_includes actions[:elements].map { |element| element[:action_id] },
                      Concierge::Slack::Card::CORRECT
    end

    private

    def proposal(action_class: "record.plan_change", gate: "human_approval",
                 payload: { "from" => "pro", "to" => "enterprise" }, key: nil,
                 rule_ids_applied: [])
      Concierge::AgentProposal.create!(
        **@scope.key, action_class: action_class, gate: gate, payload: payload,
        created_by: "agent:billing", idempotency_key: key || "key-#{action_class}",
        rule_ids_applied: rule_ids_applied
      )
    end
  end
end
