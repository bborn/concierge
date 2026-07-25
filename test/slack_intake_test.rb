require "test_helper"

module Concierge
  # The inbound half of §10.7, and the handler order §2.6 specifies:
  #
  #   signed payload -> write the decision to the proposal row -> execute -> update the card
  #
  # Every test here goes through Concierge::ApprovalIntake, because a Slack button
  # and the admin form must earn identical refusals. The transport records the state
  # of the rows at the moment of each call, so the *ordering* is asserted rather
  # than assumed.
  class SlackIntakeTest < ActiveSupport::TestCase
    include ActiveJob::TestHelper

    setup do
      Concierge::Test.configure_agents!
      @transport = Concierge::Test.configure_slack!
      @tenant  = Tenant.create!(name: "Acme", plan: "pro")
      @tenant.users.create!(email: "user@acme.test")
      @subject = Concierge.config.account.build(@tenant)
      @scope   = Concierge::Scope.new(Concierge.config.agent(:billing), @subject)

      Concierge.configure do |c|
        c.proposals do
          execute("record.plan_change") { |proposal, scope| scope.subject.to_model.update!(plan: proposal.action_arguments[:to]) }
          precondition("record.plan_change") { |scope| { "plan" => scope.subject[:plan] } }
        end
      end
    end

    # --- approve --------------------------------------------------------------

    test "Approve writes the decision, executes it, and only then updates the card" do
      row = propose

      Concierge::Slack::Intake.handle(click(Concierge::Slack::Card::APPROVE, row))

      row.reload
      assert_equal "executed", row.state
      assert_equal "slack:U9", row.approved_by
      assert row.approved_at.present?
      assert_equal "enterprise", @tenant.reload.plan

      # The ordering, asserted: by the time chat.update ran, the row was already
      # decided *and* performed. A card that updated first would be a message
      # claiming an approval the database had not recorded.
      update = @transport.last("chat.update")
      assert update, "the card was never updated"
      assert_equal "executed", update.proposal_states[row.id][:state]
      assert update.proposal_states[row.id][:executed]
    end

    test "the updated card carries who, when and what — and no buttons" do
      row = propose
      Concierge::Slack::Intake.handle(click(Concierge::Slack::Card::APPROVE, row))

      update = @transport.last("chat.update")
      assert_equal "C0BILLING", update.payload[:channel]
      assert_equal card_for(row).message_ts, update.payload[:ts]
      rendered = JSON.generate(update.payload[:blocks])
      assert_match "Executed", rendered
      assert_match "slack:U9", rendered
      refute_match "concierge_approve", rendered
    end

    test "maker-checker refuses the proposer's own click and leaves the row alone" do
      row = propose(created_by: "slack:U9")

      result = Concierge::Slack::Intake.handle(click(Concierge::Slack::Card::APPROVE, row))

      assert_equal :refused, result.status
      assert_equal "proposed", row.reload.state
      assert_match(/cannot also approve it/, @transport.last("chat.postEphemeral").payload[:text])
      assert_empty @transport.calls_to("chat.update"), "a refused click still redrew the card"
    end

    test "an unidentifiable clicker gets no approval on record" do
      # Fails closed: an approval whose approver is unknown is not maker-checked,
      # which is the whole reason this is a Slack app and not an incoming webhook.
      @transport = Concierge::Test.configure_slack!(actor_for: ->(_user) { nil })
      row = propose

      result = Concierge::Slack::Intake.handle(click(Concierge::Slack::Card::APPROVE, row, user: {}))

      assert_equal :refused, result.status
      assert_equal "proposed", row.reload.state
    end

    test "without an actor_for mapping the Slack user id is the actor" do
      row = propose

      Concierge::Slack::Intake.handle(click(Concierge::Slack::Card::APPROVE, row))

      assert_equal "slack:U9", row.reload.approved_by
    end

    test "a decision survives a card update that fails" do
      # Postgres is the record. A stale card with a correct row is recoverable; the
      # reverse is a decision that exists only in a chat message.
      row = propose
      @transport.fail_with = Concierge::Slack::ApiError.new("message_not_found")

      Concierge::Slack::Intake.handle(click(Concierge::Slack::Card::APPROVE, row))

      assert_equal "executed", row.reload.state
      assert_equal "enterprise", @tenant.reload.plan
    end

    test "an approval whose execution is refused is not reported as a success" do
      row = propose
      # The world moved between the draft and the click.
      @tenant.update!(plan: "starter")

      result = Concierge::Slack::Intake.handle(click(Concierge::Slack::Card::APPROVE, row))

      assert_equal :refused, result.status
      assert_equal "approved", row.reload.state
      assert_match(/approved but not performed/, @transport.last("chat.postEphemeral").payload[:text])
      assert_match(/state this proposal assumed has changed/, row.execution_error)
      # ...and it is exactly where step 3 put it: approved, unperformed, visible.
      assert_includes Concierge::AgentProposal.unexecuted.map(&:id), row.id
    end

    test "a human_execution proposal is approved but never executed by the engine" do
      row = propose(action_class: "money.refund", gate: "human_execution", key: "refund-1",
                    payload: { "amount_cents" => "2500" })

      Concierge::Slack::Intake.handle(click(Concierge::Slack::Card::APPROVE, row))
      assert_equal "approved", row.reload.state

      Concierge::Slack::Intake.handle(click(Concierge::Slack::Card::MARK_EXECUTED, row))
      assert_equal "executed", row.reload.state
      assert_equal "slack:U9", row.executed_by
    end

    test "a guard rule activated after the draft still blocks the click" do
      rule = Concierge::Rules.propose(
        @scope, body: "Never move an account to enterprise from Slack.", author: "drafter",
        enforcement: "guard",
        predicate: { "action_class" => "record.plan_change",
                     "deny_when" => { "to" => { "eq" => "enterprise" } } }
      )
      Concierge::Rules.activate!(rule, by: "sam@acme.test")
      row = propose

      result = Concierge::Slack::Intake.handle(click(Concierge::Slack::Card::APPROVE, row))

      assert_equal :refused, result.status
      assert_equal "approved", row.reload.state
      assert_match "blocked by guard rule", row.execution_error
      assert_equal "pro", @tenant.reload.plan
    end

    # --- reject ---------------------------------------------------------------

    test "Reject opens a modal rather than deciding on the spot" do
      row = propose

      Concierge::Slack::Intake.handle(click(Concierge::Slack::Card::REJECT, row))

      view = @transport.last("views.open").payload[:view]
      assert_equal Concierge::Slack::Card::REJECT_MODAL, view[:callback_id]
      assert_equal "proposed", row.reload.state, "clicking Reject decided something"
    end

    test "submitting the reject modal records the reason on the row" do
      row = propose

      Concierge::Slack::Intake.handle(
        submit(Concierge::Slack::Card::REJECT_MODAL, row,
               Concierge::Slack::Card::REASON_BLOCK => "wrong account")
      )

      row.reload
      assert_equal "rejected", row.state
      assert_equal "wrong account", row.rejected_reason
      assert_equal "slack:U9", row.rejected_by
      assert_match "wrong account", JSON.generate(@transport.last("chat.update").payload[:blocks])
    end

    test "a whitespace reason is refused in the modal, not stored" do
      # Slack enforces "required" for an empty input and happily submits a space.
      row = propose

      result = Concierge::Slack::Intake.handle(
        submit(Concierge::Slack::Card::REJECT_MODAL, row, Concierge::Slack::Card::REASON_BLOCK => "   ")
      )

      assert_equal "errors", result.body[:response_action]
      assert_match(/reason is required/, result.body[:errors][Concierge::Slack::Card::REASON_BLOCK])
      assert_equal "proposed", row.reload.state
    end

    test "a gate refusal on submission comes back inside the modal" do
      row = propose

      result = Concierge::Slack::Intake.handle(
        submit(Concierge::Slack::Card::REJECT_MODAL, row.tap { |r| r.update!(state: "expired") },
               Concierge::Slack::Card::REASON_BLOCK => "too late")
      )

      assert_equal "errors", result.body[:response_action]
      assert_match(/nothing to decide|expired/, result.body[:errors].values.first)
    end

    # --- correct --------------------------------------------------------------

    test "Correct edits the payload, keeps the original, and approves the edit" do
      row = propose

      Concierge::Slack::Intake.handle(
        submit(Concierge::Slack::Card::CORRECT_MODAL, row,
               "#{Concierge::Slack::Card::PAYLOAD_PREFIX}from" => "pro",
               "#{Concierge::Slack::Card::PAYLOAD_PREFIX}to"   => "starter")
      )

      row.reload
      assert_equal "starter", row.payload["to"]
      assert_equal "enterprise", row.original_payload["to"], "the agent's draft was not kept"
      assert_equal "slack:U9", row.corrected_by
      assert_equal "executed", row.state
      assert_equal "starter", @tenant.reload.plan
    end

    test "a correction cannot smuggle in a key the agent never proposed" do
      row = propose

      Concierge::Slack::Intake.handle(
        submit(Concierge::Slack::Card::CORRECT_MODAL, row,
               "#{Concierge::Slack::Card::PAYLOAD_PREFIX}to"        => "starter",
               "#{Concierge::Slack::Card::PAYLOAD_PREFIX}refund_to" => "attacker@example.test")
      )

      refute_includes row.reload.payload.keys, "refund_to"
    end

    test "a correction note opens the rule write path as a proposal, never an active rule" do
      row = propose

      assert_enqueued_jobs 1, only: Concierge::RuleGeneralizerJob do
        Concierge::Slack::Intake.handle(
          submit(Concierge::Slack::Card::CORRECT_MODAL, row,
                 "#{Concierge::Slack::Card::PAYLOAD_PREFIX}to" => "starter",
                 Concierge::Slack::Card::RULE_BLOCK => "Never upgrade a plan without asking finance first.")
        )
      end

      # The correction is stored verbatim in this agent's namespace...
      assert_includes Concierge::Memory.for_scope(@scope).map(&:body),
                      "Never upgrade a plan without asking finance first."
      # ...and no rule went active on a click.
      assert_equal 0, Concierge::AgentRule.active.count
    end

    test "a refused correction captures no rule" do
      # A correction that was refused is not evidence of anything to learn from.
      row = propose(created_by: "slack:U9")

      Concierge::Slack::Intake.handle(
        submit(Concierge::Slack::Card::CORRECT_MODAL, row,
               "#{Concierge::Slack::Card::PAYLOAD_PREFIX}to" => "starter",
               Concierge::Slack::Card::RULE_BLOCK => "something the agent should learn")
      )

      assert_equal "proposed", row.reload.state
      assert_equal 0, Concierge::Memory.for_scope(@scope).where(category: "slack_correction").count
    end

    # --- case threads ---------------------------------------------------------

    test "a human writing in a case thread has it captured against that case" do
      row  = propose
      card = card_for(row)

      Concierge::Slack::Intake.handle_event(
        thread_message(card, "They asked us to hold off until their finance review.")
      )

      assert_includes Concierge::Memory.for_scope(@scope).map(&:body),
                      "They asked us to hold off until their finance review."
    end

    test "the engine's own messages in a thread are not captured" do
      row  = propose
      card = card_for(row)

      Concierge::Slack::Intake.handle_event(
        thread_message(card, "Approval needed: record.plan_change").deep_merge(
          "event" => { "bot_id" => "B123" }
        )
      )

      assert_equal 0, Concierge::Memory.for_scope(@scope).where(category: "slack_thread").count
    end

    test "a message in an unknown thread is ignored rather than guessed at" do
      result = Concierge::Slack::Intake.handle_event(
        { "type" => "event_callback",
          "event" => { "type" => "message", "channel" => "C0BILLING",
                       "thread_ts" => "0.0", "text" => "hello?", "user" => "U9" } }
      )

      assert_equal :ignored, result.status
      assert_equal 0, Concierge::Memory.where(category: "slack_thread").count
    end

    test "the URL handshake is answered with the challenge and nothing else" do
      result = Concierge::Slack::Intake.handle_event(
        { "type" => "url_verification", "challenge" => "abc123" }
      )

      assert_equal({ challenge: "abc123" }, result.body)
    end

    test "a payload type this seam does not handle changes nothing" do
      assert_equal :ignored, Concierge::Slack::Intake.handle({ "type" => "shortcut" }).status
    end

    private

    def propose(action_class: "record.plan_change", gate: nil, key: nil, created_by: nil,
                payload: { "from" => "pro", "to" => "enterprise" })
      row = Concierge::Proposal.propose(@scope, action_class: action_class, payload: payload,
                                                created_by: created_by,
                                                idempotency_key: key || "key-#{action_class}")
      row.update_columns(gate: gate) if gate
      row
    end

    def card_for(row)
      Concierge::SlackCard.find_by(agent_proposal_id: row.id)
    end

    def click(action_id, row, user: { "id" => "U9" })
      card = card_for(row)
      {
        "type" => "block_actions",
        "user" => user,
        "trigger_id" => "T1",
        "container" => { "channel_id" => card&.channel_id, "message_ts" => card&.message_ts },
        "actions" => [ { "action_id" => action_id, "value" => row.id.to_s } ]
      }
    end

    def submit(callback_id, row, values = {})
      card = card_for(row)
      state = values.to_h do |block_id, value|
        [ block_id, { Concierge::Slack::Card::INPUT_ACTION => { "value" => value } } ]
      end

      {
        "type" => "view_submission",
        "user" => { "id" => "U9" },
        "view" => {
          "callback_id" => callback_id,
          "private_metadata" => JSON.generate("proposal_id" => row.id,
                                              "channel" => card&.channel_id,
                                              "ts" => card&.message_ts),
          "state" => { "values" => state }
        }
      }
    end

    def thread_message(card, text)
      {
        "type" => "event_callback",
        "event" => { "type" => "message", "channel" => card.channel_id,
                     "thread_ts" => card.thread_ts, "text" => text, "user" => "U9" }
      }
    end
  end
end
