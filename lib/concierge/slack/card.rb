module Concierge
  module Slack
    # The Block Kit card a proposal is decided from (§2.6, design §10.7), and the
    # two modals that carry the text a button cannot: a rejection's **reason**
    # (required — §2.5) and a correction's edited payload.
    #
    # Everything a human needs to decide is on the card and nothing more: what
    # would happen, under which gate, who proposed it, which rules steered it, and
    # what it assumed about the world. The card also says, in as many words, that
    # the queue in the admin is the record — because the whole point of §10.7 is
    # that Slack going down costs convenience and not authority.
    #
    # A decided card is *replaced* rather than annotated: buttons that would now be
    # refused must stop being clickable, and a card still showing Approve after
    # someone approved is how two people think they are the decider.
    class Card
      APPROVE       = "concierge_approve".freeze
      REJECT        = "concierge_reject".freeze
      CORRECT       = "concierge_correct".freeze
      MARK_EXECUTED = "concierge_mark_executed".freeze
      ACTIONS_BLOCK = "concierge_proposal_actions".freeze

      REJECT_MODAL  = "concierge_reject_modal".freeze
      CORRECT_MODAL = "concierge_correct_modal".freeze

      REASON_BLOCK  = "concierge_reason".freeze
      RULE_BLOCK    = "concierge_rule".freeze
      PAYLOAD_PREFIX = "concierge_payload:".freeze
      INPUT_ACTION  = "value".freeze

      # +executing+ says the decision has just been handed to
      # ProposalExecutionJob and the executor has not run yet. The row carries the
      # same fact (execution_queued_at, stamped by whoever queued it), because a
      # surface that did *not* queue it — the admin queue, a later redraw — has
      # nothing else to read: "approved, nothing recorded" and "approved, queued
      # and running right now" are otherwise the same three columns. This flag
      # stays as the in-request override, for the caller that knows before the row
      # is re-read.
      def initialize(proposal, executing: false)
        @proposal  = proposal
        @executing = executing
      end

      # The card as posted. A proposal awaiting a human gets buttons; anything
      # already decided gets the audit trail instead.
      def blocks
        return decided_blocks unless proposal.proposed? && !proposal.expired?

        [
          header,
          summary_section,
          facts_section,
          *provenance_context,
          actions,
          record_context
        ].compact
      end

      # What the card becomes once someone decides: who, when, what — the same
      # three things the row now holds.
      def decided_blocks
        [
          header,
          summary_section,
          decision_section,
          record_context
        ].compact
      end

      # The notification line. Short, because it is what a phone shows.
      def text
        "#{verb} — #{proposal.agent_slug} · #{proposal.action_class} (proposal ##{proposal.id})"
      end

      # --- modals ---------------------------------------------------------------

      # §2.5: a rejection requires a reason. It is the only record of why the
      # draft was wrong, and the one signal the agent's operators get.
      def reject_modal(metadata)
        {
          type: "modal",
          callback_id: REJECT_MODAL,
          private_metadata: JSON.generate(metadata),
          title: plain("Reject proposal", 24),
          submit: plain("Reject"),
          close: plain("Cancel"),
          blocks: [
            context_block("*#{proposal.action_class}* · proposal ##{proposal.id} · #{proposal.agent_slug}"),
            {
              type: "input",
              block_id: REASON_BLOCK,
              label: plain("Why not?"),
              hint: plain("Required. A decision nobody can read the reasoning of is not an audit trail."),
              element: {
                type: "plain_text_input", action_id: INPUT_ACTION, multiline: true
              }
            }
          ]
        }
      end

      # Edit-then-approve. The correction is also the doorway to the rule write
      # path (§10.2): a human who just fixed a draft is the best-placed person in
      # the system to say what the agent should do differently next time, and that
      # sentence becomes a *proposed* rule — never an active one.
      def correct_modal(metadata)
        {
          type: "modal",
          callback_id: CORRECT_MODAL,
          private_metadata: JSON.generate(metadata),
          title: plain("Correct and approve", 24),
          submit: plain("Approve"),
          close: plain("Cancel"),
          blocks: [
            context_block("*#{proposal.action_class}* · proposal ##{proposal.id} · #{proposal.agent_slug}"),
            *payload_inputs,
            {
              type: "input",
              block_id: RULE_BLOCK,
              optional: true,
              label: plain("What should the agent do differently next time?"),
              hint: plain("Optional. Becomes a proposed rule for a human to approve — never an active one."),
              element: {
                type: "plain_text_input", action_id: INPUT_ACTION, multiline: true
              }
            }
          ]
        }
      end

      # One input per payload key, so a correction stays inside the arguments the
      # action class already declared. A modal cannot grow a key the agent never
      # proposed — that would be a human authoring a *different* action under an
      # approval trail that says otherwise.
      def payload_inputs
        editable_payload.map do |key, value|
          {
            type: "input",
            block_id: "#{PAYLOAD_PREFIX}#{key}",
            label: plain(key.to_s.tr("_", " "), 24),
            element: {
              type: "plain_text_input",
              action_id: INPUT_ACTION,
              multiline: key.to_s == "body",
              initial_value: Text.safe(value, limit: 2000)
            }.compact
          }
        end
      end

      # Scalars only: a nested structure has no honest single-line editor, and
      # guessing at one is how a correction quietly drops half a payload.
      def editable_payload
        proposal.payload.reject { |_key, value| value.is_a?(Hash) || value.is_a?(Array) }
      end

      private

      attr_reader :proposal

      def verb
        return "Approval needed" if proposal.proposed?

        "Proposal #{proposal.state}"
      end

      def header
        { type: "header", text: plain("#{verb}: #{proposal.action_class}", 150) }
      end

      def summary_section
        lines = [ "*#{proposal.agent_slug}* on *#{proposal.subject_type} ##{proposal.subject_id}*" ]
        if proposal.message?
          lines << ">#{Text.safe(proposal.body).gsub("\n", "\n>")}"
          lines << "_via #{proposal.channel || 'whichever channel can reach them'}_"
        else
          proposal.payload.each { |key, value| lines << "• *#{key}*: #{Text.safe(value, limit: 300)}" }
        end
        lines << ":loudspeaker: _this draft tried to notify a whole channel; the ping was removed_" if shouted?

        mrkdwn(lines.join("\n"))
      end

      def shouted?
        proposal.payload.values.any? { |value| Text.broadcast?(value) }
      end

      def facts_section
        {
          type: "section",
          fields: [
            mrkdwn_field("*Gate*\n#{gate_line}"),
            mrkdwn_field("*Proposed by*\n#{proposal.created_by}"),
            mrkdwn_field("*Proposed at*\n#{proposal.proposed_at}"),
            mrkdwn_field("*Expires*\n#{proposal.expires_at || 'never'}")
          ]
        }
      end

      def gate_line
        return "human execution — approve it, then do it yourself" if proposal.human_execution?

        "human approval — approving executes it"
      end

      def provenance_context
        notes = []
        if proposal.rule_ids_applied.any?
          # Its own claim, and flagged as one — a model can cite a rule while
          # contradicting it, so this is never proof of compliance (§10.4).
          notes << "Rules the agent claims it applied (unverified): " \
                   "#{proposal.rule_ids_applied.map { |id| "##{id}" }.join(', ')}"
        end
        if proposal.precondition_digest.present?
          notes << "Assumed state `#{proposal.precondition_digest}` — re-checked at execution"
        end
        notes << "Last refusal: #{proposal.execution_error}" if proposal.execution_error.present?
        return [] if notes.empty?

        [ context_block(notes.join(" · ")) ]
      end

      def decision_section
        mrkdwn(decision_lines.join("\n"))
      end

      def decision_lines
        lines = []
        if proposal.rejected?
          lines << ":x: *Rejected* by #{proposal.rejected_by} at #{proposal.rejected_at}"
          lines << "> #{Text.safe(proposal.rejected_reason)}"
        elsif proposal.executed?
          lines << ":white_check_mark: *Executed* at #{proposal.executed_at} " \
                   "by #{proposal.executed_by.presence || 'the engine'}"
          lines << "Approved by #{proposal.approved_by}" if proposal.approved_by.present?
        elsif proposal.approved?
          lines << ":hourglass: *Approved* by #{proposal.approved_by} at #{proposal.approved_at} — " \
                   "#{unexecuted_reason}"
        else
          lines << ":no_entry: *Expired* unapproved on #{proposal.expires_at} — " \
                   "it has to be re-proposed against current state"
        end
        lines << "_Corrected first by #{proposal.corrected_by}._" if proposal.corrected?
        lines
      end

      # An approval whose execution was refused must not read as a success. Step 3
      # learned this on the admin queue; a card that said "Approved" and stopped
      # there would put it back.
      def unexecuted_reason
        return "the engine does not perform this one; you do" if proposal.human_execution?
        return "not performed: #{proposal.execution_error}" if proposal.execution_error.present?
        # Deliberately not "executing" or "done in a moment": what is true is that
        # it is queued. If nothing ever runs the queue, this card has said so.
        #
        # Two sources, one sentence. +@executing+ is this request telling the card
        # what it just did; the row is for every other redraw — a retry queued
        # from elsewhere, an ExecutionReport, a card rebuilt from scratch — none of
        # which were the caller that queued anything.
        return "queued to be performed — this card updates when it is" if @executing || proposal.execution_queued?

        "not performed yet"
      end

      def actions
        buttons = [
          button("Approve", APPROVE, style: "primary"),
          button("Reject", REJECT, style: "danger")
        ]
        buttons.insert(1, button("Correct…", CORRECT)) if editable_payload.any?

        { type: "actions", block_id: ACTIONS_BLOCK, elements: buttons }
      end

      def button(label, action_id, style: nil)
        {
          type: "button",
          action_id: action_id,
          text: plain(label, 75),
          value: proposal.id.to_s,
          style: style
        }.compact
      end

      # The line that makes the outage story true out loud.
      def record_context
        context_block("Slack is the remote control; the record is " \
                      "`/concierge/admin/proposals` — proposal ##{proposal.id}.")
      end

      def plain(text, limit = 150)
        { type: "plain_text", text: Text.safe(text, limit: limit) }
      end

      def mrkdwn(text)
        { type: "section", text: { type: "mrkdwn", text: Text.safe(text) } }
      end

      def mrkdwn_field(text)
        { type: "mrkdwn", text: Text.safe(text, limit: 2000) }
      end

      def context_block(text)
        { type: "context", elements: [ { type: "mrkdwn", text: Text.safe(text, limit: 2000) } ] }
      end
    end
  end
end
