module Concierge
  # An action an agent proposed but is not allowed to perform on its own
  # (design §10.6). The generalization of +OutboxItem+, which staged exactly one
  # action class — an outbound message — and only when the global
  # +draft_and_review+ boolean was on.
  #
  #   action_class  "message.outreach", "record.update", "money.refund", …
  #   payload       the serialized arguments for that action
  #   gate          the authority level that *demanded* a proposal, snapshotted
  #                 at propose time so a later config change cannot retroactively
  #                 loosen a pending one
  #
  # Four rules of the object, all enforced here or in Concierge::Proposal:
  #
  # 1. **Maker-checker.** +created_by ≠ approved_by+. The proposer can never
  #    approve its own proposal, and an +agent:+ actor can never approve at all.
  # 2. **Execute only from an approved record.** There is no approve-and-execute
  #    call that skips the row; Proposal::Execute reads an +approved+ row.
  # 3. **Mutually-exclusive outcomes.** A proposal was approved or rejected,
  #    never both — and a rejection carries a reason.
  # 4. **Exactly-once execution**, per +idempotency_key+.
  #
  # The lifecycle lives in Concierge::Proposal and Concierge::ApprovalIntake, not
  # here: the gate, the maker-checker refusal and the precondition re-validation
  # are policy, and policy that has to fail loudly and explain itself does not
  # belong in a model callback.
  class AgentProposal < ApplicationRecord
    include AgentScoped

    # proposed -> approved -> executed, plus the two ways a proposal ends without
    # ever being performed. `expired` is not `rejected`: nobody declined it, it
    # simply went stale, and an audit that conflated the two would misreport what
    # the humans in the loop actually did.
    STATES = %w[proposed approved rejected executed expired].freeze

    # The two authority levels that produce a proposal at all. :autonomous is
    # deliberately absent — an autonomous action has nothing to stage, so a row
    # carrying that gate would be a proposal nobody ever has to look at.
    GATES = %w[human_approval human_execution].freeze

    serialize :payload,          coder: JSON, type: Hash
    serialize :original_payload, coder: JSON, type: Hash
    serialize :rule_ids_applied, coder: JSON, type: Array

    validates :action_class, presence: true
    validates :state, inclusion: { in: STATES }
    validates :gate,  inclusion: { in: GATES }
    validates :idempotency_key, presence: true, uniqueness: true
    validate  :maker_is_not_the_checker
    validate  :outcomes_are_mutually_exclusive
    validate  :rejection_carries_a_reason

    scope :proposed, -> { where(state: "proposed") }
    scope :approved, -> { where(state: "approved") }
    scope :executed, -> { where(state: "executed") }
    scope :rejected, -> { where(state: "rejected") }
    scope :expired,  -> { where(state: "expired") }
    scope :recent,   -> { order(created_at: :desc, id: :desc) }
    scope :of_action_class, ->(action_class) { where(action_class: action_class.to_s) }

    # Proposals a human still has to look at, oldest first — a queue, not a feed.
    scope :awaiting, -> { proposed.order(:created_at, :id) }

    # Approved but not performed. For a :human_approval proposal that is a
    # transient state; for :human_execution it is where the row *waits* for the
    # human to go and do the thing.
    scope :unexecuted, -> { approved.order(:approved_at, :id) }

    scope :past_due, ->(now = Time.current) {
      proposed.where.not(expires_at: nil).where(expires_at: ...now)
    }

    # The old name for `proposed`. §10.9 keeps `Concierge::OutboxItem` working for
    # a release; a host's `OutboxItem.pending` should keep working with it.
    scope :pending, -> { proposed }

    before_validation :stamp_proposed_at, on: :create

    def proposed? = state == "proposed"
    def approved? = state == "approved"
    def executed? = state == "executed"
    def rejected? = state == "rejected"

    # Approved and waiting to be performed. Deliberately not "approved?" — the
    # question callers actually ask is whether there is still work to do.
    def executable? = approved? && !executed?

    # Money and anything else the engine must not perform itself (§10.5): a human
    # approves *and* executes, and the engine's job ends at recording that.
    def human_execution? = gate == "human_execution"

    def expired?(now = Time.current)
      return true if state == "expired"

      expires_at.present? && expires_at < now && !executed?
    end

    # Serialized bags read as their empty selves even on a row that predates the
    # column, so no caller has to nil-check them.
    def payload          = super || {}
    def original_payload = super || {}
    def rule_ids_applied = super || []

    # The payload as the action's own code wants it: JSON round-trips string keys,
    # and every executor in the engine (and every channel) speaks symbols.
    def action_arguments
      payload.deep_symbolize_keys
    end

    # The one action class the engine dispatches itself. Everything else needs a
    # host-registered executor (§10.6, §10.8).
    def message?
      action_class.to_s.start_with?("message.")
    end

    # Convenience readers for the built-in message action. Deliberately readers
    # only, and deliberately derived: the payload is the single source of truth
    # for what this proposal would do.
    def body    = payload["body"]
    def channel = payload["channel"]
    def kind    = payload["kind"] || "outreach"

    # A one-line description for a queue view: what would happen if this were
    # approved.
    def summary
      return body.to_s if message?

      payload.map { |key, value| "#{key}: #{value}" }.join(", ")
    end

    # Was the agent's draft edited by the human who approved it (§10.7)?
    def corrected? = corrected_at.present?

    def execution_failed? = execution_failed_at.present?

    private

    def stamp_proposed_at
      self.proposed_at ||= Time.current
    end

    # Maker-checker, at the row level. Proposal::ApprovalIntake refuses this
    # earlier and with a better message; the validation is here because "the
    # proposer approved its own proposal" must not be reachable by any other
    # write path either.
    def maker_is_not_the_checker
      return if approved_by.blank? || created_by.blank?
      return unless approved_by.to_s.strip == created_by.to_s.strip

      errors.add(:approved_by, "cannot be the actor that proposed it (maker-checker)")
    end

    def outcomes_are_mutually_exclusive
      return if approved_at.blank? || rejected_at.blank?

      errors.add(:rejected_at, "and approved_at are mutually exclusive — " \
                               "a proposal was approved or declined, never both")
    end

    def rejection_carries_a_reason
      return unless state == "rejected"
      return if rejected_reason.to_s.strip.present?

      errors.add(:rejected_reason, "is required to reject a proposal")
    end
  end
end
