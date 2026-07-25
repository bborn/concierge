module Concierge
  # A generalized, versioned, human-gated behavioral instruction (design §10.2).
  #
  # This is the half of what +Concierge::Memory+ used to do that never belonged
  # there. Memory is episodic and about *this relationship* ("renewal is in
  # March"). A rule is generalized and about *how to behave* ("never promise a
  # delivery date without checking the shipping API") — so unlike a memory it is
  # versioned, has a lifecycle, and cannot go live without a human tap.
  #
  # Scoping is the one place the (Agent × Subject) key is deliberately partial:
  #
  #   agent_slug            always required — a rule steers ONE business function
  #   subject_type/_id nil  the rule applies to every account this agent serves
  #   segment          set  applies to a named segment (see Rules.segments_for)
  #
  # There is no shared namespace for rules. §10.3's +_shared+ exists for *facts*
  # every agent legitimately reads; an instruction that crosses agents is the
  # cross-function contamination this phase exists to prevent.
  #
  # Lifecycle transitions live in Concierge::Rules, not here: the human gate, the
  # conflict check and the active-rule cap are policy, and a model callback is the
  # wrong place for a policy that has to fail loudly and explain itself.
  class AgentRule < ApplicationRecord
    include AgentScoped

    STATES       = %w[proposed active deprecated rejected].freeze
    ENFORCEMENTS = %w[advisory guard].freeze

    # Editing any of these changes the *instruction*, so it bumps the version —
    # which is what a provenance snapshot pins. A state transition does not: the
    # text a run was given did not change when a human tapped Approve.
    VERSIONED_ATTRIBUTES = %w[body predicate enforcement segment].freeze

    serialize :provenance,           coder: JSON, type: Hash
    serialize :predicate,            coder: JSON, type: Hash
    serialize :deprecation_evidence, coder: JSON, type: Hash

    belongs_to :superseded_by, class_name: "Concierge::AgentRule", optional: true
    has_many   :revisions, -> { order(:version, :id) },
               class_name: "Concierge::AgentRuleRevision",
               foreign_key: :agent_rule_id, dependent: :destroy,
               inverse_of: :agent_rule

    validates :body,        presence: true
    validates :state,       inclusion: { in: STATES }
    validates :enforcement, inclusion: { in: ENFORCEMENTS }
    validate  :subject_keys_travel_together

    scope :proposed,   -> { where(state: "proposed") }
    scope :active,     -> { where(state: "active") }
    scope :deprecated, -> { where(state: "deprecated") }
    scope :agent_wide, -> { where(subject_type: nil, subject_id: nil) }
    scope :retirement_proposed, -> { where.not(deprecation_proposed_at: nil) }

    # Every rule whose scope covers +target+ (a Scope or a bare Subject): this
    # agent's agent-wide rules, its rules for the segments this subject is in,
    # and its rules for this subject specifically. Never another agent's, and
    # never another subject's.
    #
    # Ordered broad -> specific, so the prompt reads as refinements: the
    # account-specific instruction lands after the blanket one it narrows.
    scope :applicable_to, ->(target, segments: nil) {
      scope   = Scope.coerce(target)
      subject = scope.subject.key

      where(agent_slug: scope.agent_slug)
        .where("(subject_type IS NULL AND subject_id IS NULL) OR " \
               "(subject_type = :type AND subject_id = :id)",
               type: subject[:subject_type], id: subject[:subject_id])
        .where(segment: [ nil ] + Array(segments).map(&:to_s))
        .order(Arel.sql("CASE WHEN subject_id IS NOT NULL THEN 2 " \
                        "WHEN segment IS NOT NULL THEN 1 ELSE 0 END"), :id)
    }

    # The rules that could land in *one prompt* with this one: same agent, and
    # scopes that nest (either side is agent-wide, or both name the same subject).
    # What the conflict check compares against (§10.2).
    #
    # Symmetric on purpose. A blanket "always attach the invoice" and an
    # account-specific "never attach the invoice" contradict each other whichever
    # order they were written in, and a directional relation would see the
    # contradiction from one side only.
    scope :shares_prompt_with, ->(rule) {
      relation = where(agent_slug: rule.agent_slug)
      if rule.subject_id.present?
        relation = relation.where("(subject_type IS NULL AND subject_id IS NULL) OR " \
                                  "(subject_type = :type AND subject_id = :id)",
                                  type: rule.subject_type, id: rule.subject_id)
      end
      relation = relation.where(segment: [ nil, rule.segment ].uniq) if rule.segment.present?
      relation
    }

    before_create :stamp_proposed_at
    before_save   :bump_version_on_edit
    after_save    :record_revision

    def active?     = state == "active"
    def proposed?   = state == "proposed"
    def deprecated? = state == "deprecated"

    # An advisory rule is prompt-only; a guard rule carries a predicate the
    # engine can check itself, short-circuiting the model (§10.2).
    def guard? = enforcement == "guard" && predicate.present?

    # Conflicts found at propose time, kept on the row so the proposal card can
    # show them and activation can refuse until a human resolves them.
    def conflicts = Array(provenance["conflicts"])
    def conflicts? = conflicts.any?

    # The rules this proposal would merge, when the dreaming job (or a human)
    # proposed it as a consolidation.
    def merges = Array(provenance["merges"]).map(&:to_i)

    def retirement_proposed? = deprecation_proposed_at.present?

    # What a provenance snapshot pins (§10.4). The pair, not the text — the text
    # at that version is recoverable from the revision trail even after an edit.
    def pin = { "id" => id, "version" => version }

    # How the rule renders in the prompt's Playbook section. The id is in there
    # so the agent can cite what it applied, and the version so a reader of the
    # transcript can find the exact text again.
    def to_prompt = "[rule #{id} v#{version}] #{body.to_s.strip}"

    # The revision in force at +version+ — the audit lookup a pinned provenance
    # snapshot resolves through.
    def revision_at(version) = revisions.where(version: version).last

    # Who is moving this rule, and why, for the next revision row. Set by
    # Concierge::Rules around a transition; cleared once recorded.
    def revision_context(actor: nil, note: nil)
      @revision_actor = actor
      @revision_note  = note
    end

    # Serialized columns read as a Hash even when the row predates the default,
    # so callers never have to nil-check a bag of metadata.
    def provenance           = super || {}
    def deprecation_evidence = super || {}

    private

    def bump_version_on_edit
      return unless persisted?
      return if (changed & VERSIONED_ATTRIBUTES).empty?

      self.version = version + 1
    end

    def stamp_proposed_at
      self.proposed_at ||= Time.current
    end

    # One row per material change — the paper trail. State transitions are
    # recorded too (at the version then in force), because "when did this go
    # live, and who tapped it" is half of what the trail is for.
    def record_revision
      tracked = VERSIONED_ATTRIBUTES + [ "state" ]
      return unless saved_changes.key?("id") || saved_changes.keys.intersect?(tracked)

      revisions.create!(
        version:     version,
        body:        body,
        state:       state,
        predicate:   predicate,
        enforcement: enforcement,
        actor:       @revision_actor || approver || author,
        note:        @revision_note,
        created_at:  Time.current
      )
    ensure
      @revision_actor = nil
      @revision_note  = nil
    end

    def subject_keys_travel_together
      return if subject_type.blank? == subject_id.blank?

      errors.add(:subject_id, "and subject_type must both be set, or both be blank")
    end
  end
end
