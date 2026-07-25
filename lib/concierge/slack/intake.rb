require "json"

module Concierge
  module Slack
    # The inbound half of §10.7 — the seam's Slack adapter, and *only* an adapter.
    # It authenticates nothing itself (the controller verified the signature before
    # this runs), decides nothing itself, and executes nothing itself: every
    # decision goes through Concierge::ApprovalIntake, which is where maker-checker,
    # the gate and the precondition re-validation live. A Slack button and the admin
    # form take the identical path and earn the identical refusals.
    #
    # The handler order is the load-bearing part (§2.6), and it is this, in this
    # order, on purpose:
    #
    #   1. **signed payload** — the controller, before a single write;
    #   2. **write the decision to the proposal row** — who, when, what;
    #   3. **execute** — from that approved row and nothing else;
    #   4. **update the card.**
    #
    # Step 4 is last and is allowed to fail. Postgres is the record; the card is a
    # view of it. A failed `chat.update` leaves a stale card and a correct row,
    # which is recoverable — the reverse would be a decision that exists only in a
    # chat message.
    class Intake
      # What the controller should answer Slack with. Slack wants a 200 within
      # three seconds and treats a body as instructions, so "nothing to say" and
      # "show this error in the modal" are different results.
      Result = Struct.new(:status, :body, keyword_init: true) do
        def json? = body.is_a?(Hash)
      end

      OK      = Result.new(status: :ok).freeze
      IGNORED = Result.new(status: :ignored).freeze

      class << self
        # An interactivity payload: a button click or a modal submission.
        def handle(payload)
          payload = normalize(payload)

          case payload["type"]
          when "block_actions"   then new(payload).handle_action
          when "view_submission" then new(payload).handle_submission
          else IGNORED
          end
        end

        # An Events API payload. Two things arrive here: Slack's one-time URL
        # handshake, and humans typing in a case thread.
        def handle_event(payload)
          payload = normalize(payload)

          case payload["type"]
          when "url_verification" then Result.new(status: :ok, body: { challenge: payload["challenge"] })
          when "event_callback"   then new(payload).handle_thread_message
          else IGNORED
          end
        end

        private

        def normalize(payload)
          (payload || {}).to_h.transform_keys(&:to_s)
        end
      end

      def initialize(payload)
        @payload = payload
      end

      # --- 1. a button ----------------------------------------------------------

      def handle_action
        action = Array(payload["actions"]).first.to_h.transform_keys(&:to_s)
        proposal = AgentProposal.find_by(id: action["value"])
        return refuse("that proposal no longer exists") unless proposal
        return refuse(no_actor_message) if actor.blank?

        case action["action_id"]
        when Card::APPROVE       then decide(proposal) { ApprovalIntake.approve(proposal, by: actor) }
        when Card::MARK_EXECUTED then decide(proposal) { ApprovalIntake.record_execution(proposal, by: actor) }
        when Card::REJECT        then open_modal(Card.new(proposal).reject_modal(metadata_for(proposal)))
        when Card::CORRECT       then open_modal(Card.new(proposal).correct_modal(metadata_for(proposal)))
        else IGNORED
        end
      end

      # --- 2. a modal -----------------------------------------------------------

      def handle_submission
        view     = (payload["view"] || {}).transform_keys(&:to_s)
        metadata = parse_metadata(view["private_metadata"])
        proposal = AgentProposal.find_by(id: metadata["proposal_id"])
        return modal_error(Card::REASON_BLOCK, "that proposal no longer exists") unless proposal
        return modal_error(Card::REASON_BLOCK, no_actor_message) if actor.blank?

        case view["callback_id"]
        when Card::REJECT_MODAL  then submit_rejection(proposal, view, metadata)
        when Card::CORRECT_MODAL then submit_correction(proposal, view, metadata)
        else IGNORED
        end
      end

      def submit_rejection(proposal, view, metadata)
        reason = input(view, Card::REASON_BLOCK)
        # Slack enforces "required" for an empty input but happily submits a
        # space. §2.5 means a reason, not a keystroke.
        return modal_error(Card::REASON_BLOCK, "A reason is required — it is the only record of why this was wrong.") if reason.blank?

        decide(proposal, metadata, on_refusal: in_modal(Card::REASON_BLOCK)) do
          ApprovalIntake.reject(proposal, by: actor, reason: reason)
        end
      end

      def submit_correction(proposal, view, metadata)
        corrected = corrected_payload(proposal, view)
        note      = input(view, Card::RULE_BLOCK)
        block_id  = first_payload_block(proposal) || Card::RULE_BLOCK

        result = decide(proposal, metadata, on_refusal: in_modal(block_id)) do
          ApprovalIntake.correct(proposal, by: actor, payload: corrected)
        end

        # The rule write path (§10.2) opens only if the correction actually landed
        # on the row. A correction the gate refused is not evidence of anything the
        # agent should learn from — but one that landed and then failed to *execute*
        # is: the human still corrected the draft, and that is the feedback.
        capture_rule(proposal, note) if note.present? && proposal.reload.corrected?
        result
      end

      # --- 3. a human typing in a case thread -----------------------------------

      # One thread per case means the thread *is* an addressable case, so a human
      # writing in it is a takeover note. Routing (fact vs. behavioural rule) is
      # Learning's job, not this adapter's — it has the heuristic and the human's
      # explicit choice, and duplicating either here would be a second opinion.
      def handle_thread_message
        event = (payload["event"] || {}).transform_keys(&:to_s)
        return IGNORED unless event["type"] == "message"
        # Our own cards, edits, joins and deletions are not takeover notes — and a
        # bot reacting to its own message is an infinite loop.
        return IGNORED if event["bot_id"].present? || event["subtype"].present?

        thread = event["thread_ts"]
        return IGNORED if thread.blank? || event["text"].to_s.strip.empty?

        card = SlackCard.find_by(channel_id: event["channel"], thread_ts: thread)
        return IGNORED unless card

        scope = card.scope
        return IGNORED unless scope

        Learning.capture(scope, content: event["text"],
                                category: "slack_thread",
                                author: thread_actor(event))
        OK
      end

      private

      attr_reader :payload

      # --- the ordered handler --------------------------------------------------

      # Write the decision, execute, *then* redraw the card. The block does 2 and
      # 3 (ApprovalIntake.approve executes from the row it just wrote); this method
      # owns 4 and the fact that 4 cannot undo them.
      # +on_refusal+ is how the same refusal reaches a human in two very different
      # places: a click has a channel to whisper into, a modal submission has only
      # the modal.
      def decide(proposal, metadata = nil, on_refusal: nil)
        on_refusal ||= method(:refuse)
        outcome = yield
        proposal.reload
        refresh_card(proposal, metadata || metadata_for(proposal))

        report(proposal, outcome, on_refusal)
      rescue Concierge::Proposal::GateError => e
        # The refusals are the feature. A maker-checker refusal has to reach the
        # person who clicked, and must leave the row exactly as it was.
        on_refusal.call(e.message)
      end

      # An approval whose execution was refused is not a success and must not be
      # reported as one — the property step 3 established on the admin queue,
      # preserved here because these buttons write the same rows.
      def report(proposal, outcome, on_refusal)
        return OK if %i[executed rejected approved].include?(outcome)

        on_refusal.call(
          "Proposal ##{proposal.id} was approved but not performed " \
          "(#{outcome.to_s.tr('_', ' ')})#{": #{proposal.execution_error}" if proposal.execution_error}. " \
          "It is waiting in /concierge/admin/proposals."
        )
      end

      def in_modal(block_id)
        ->(message) { modal_error(block_id, message) }
      end

      def refresh_card(proposal, metadata)
        channel = metadata["channel"]
        ts      = metadata["ts"]
        return if channel.blank? || ts.blank?

        card = Card.new(proposal)
        client.update_message(channel: channel, ts: ts, blocks: card.decided_blocks, text: card.text)
      rescue StandardError => e
        # Deliberately swallowed. The decision is already durable; a stale card is
        # a cosmetic problem, and raising here would report a failure for something
        # that already happened.
        Concierge.logger&.warn(
          "[concierge] proposal #{proposal.id} was decided but its Slack card could not be " \
          "updated: #{e.class}: #{e.message}"
        )
      end

      def capture_rule(proposal, note)
        scope = Concierge::Scope.resolve(agent_slug: proposal.agent_slug,
                                         subject_id: proposal.subject_id)
        return Concierge.logger&.warn("[concierge] no scope for proposal #{proposal.id}; " \
                                      "the correction note was not captured") unless scope

        Learning.capture(scope, content: note, kind: :rule, author: actor,
                                category: "slack_correction",
                                provenance: { "slack_proposal_id" => proposal.id,
                                              "corrected_by" => actor })
      end

      # --- Slack plumbing -------------------------------------------------------

      def open_modal(view)
        trigger = payload["trigger_id"]
        return refuse("Slack did not send a trigger for this click, so the form cannot open") if trigger.blank?

        client.open_view(trigger_id: trigger, view: view)
        OK
      rescue StandardError => e
        Concierge.logger&.warn("[concierge] could not open a Slack modal: #{e.class}: #{e.message}")
        refuse("Slack would not open the form: #{e.message}")
      end

      # Ephemeral, so a refusal reaches the person who clicked without the channel
      # watching. Falls back to a logged warning when there is nowhere to put it —
      # a modal submission has no channel.
      def refuse(message)
        channel = container["channel_id"] || (payload.dig("channel", "id") if payload["channel"])
        user    = payload.dig("user", "id")

        if channel.present? && user.present?
          begin
            client.post_ephemeral(channel: channel, user: user, text: message)
          rescue StandardError => e
            Concierge.logger&.warn("[concierge] could not deliver a Slack refusal: #{e.message}")
          end
        else
          Concierge.logger&.info("[concierge] slack refusal (nowhere to show it): #{message}")
        end

        Result.new(status: :refused, body: nil)
      end

      def modal_error(block_id, message)
        Result.new(status: :refused,
                   body: { response_action: "errors", errors: { block_id => message } })
      end

      def metadata_for(proposal)
        {
          "proposal_id" => proposal.id,
          "channel"     => container["channel_id"] || card_for(proposal)&.channel_id,
          "ts"          => container["message_ts"] || card_for(proposal)&.message_ts
        }
      end

      def card_for(proposal)
        return @card_for if defined?(@card_for)

        @card_for = SlackCard.find_by(agent_proposal_id: proposal.id)
      end

      def container
        (payload["container"] || {}).transform_keys(&:to_s)
      end

      def parse_metadata(raw)
        parsed = JSON.parse(raw.to_s)
        parsed.is_a?(Hash) ? parsed : {}
      rescue JSON::ParserError
        {}
      end

      def input(view, block_id)
        view.dig("state", "values", block_id, Card::INPUT_ACTION, "value").to_s.strip
      end

      # Only the keys the modal offered, which are only the keys the agent already
      # proposed. A correction edits an action; it does not author a new one.
      def corrected_payload(proposal, view)
        offered = Card.new(proposal).editable_payload.keys.map(&:to_s)
        values  = (view.dig("state", "values") || {})

        values.each_with_object({}) do |(block_id, _fields), corrected|
          next unless block_id.to_s.start_with?(Card::PAYLOAD_PREFIX)

          key = block_id.to_s.delete_prefix(Card::PAYLOAD_PREFIX)
          next unless offered.include?(key)

          corrected[key] = input(view, block_id)
        end
      end

      def first_payload_block(proposal)
        key = Card.new(proposal).editable_payload.keys.first
        key && "#{Card::PAYLOAD_PREFIX}#{key}"
      end

      def actor
        return @actor if defined?(@actor)

        @actor = Concierge::Slack.settings.actor(payload["user"])
      end

      def thread_actor(event)
        Concierge::Slack.settings.actor({ "id" => event["user"] })
      end

      def no_actor_message
        "Concierge could not tell who you are, so this decision has no approver on " \
        "record. Map your Slack user to a host identity (config.slack { actor_for … })."
      end

      def client
        @client ||= Client.new
      end
    end
  end
end
