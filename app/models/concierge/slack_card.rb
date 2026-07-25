module Concierge
  # Where a proposal's approval card lives in Slack (design §10.7). Deliberately
  # a pointer and not a copy: the card carries no decision, no reason and no
  # payload, because the moment two rows can answer "was this approved?" they can
  # disagree, and the one that a Slack outage takes offline must not be the one
  # that matters.
  #
  #   SlackCard.for_scope(scope)          # this agent, this account — nothing else
  #   SlackCard.thread_ts_for(scope)      # the case thread to reply into
  #   SlackCard.posted_today(:billing)    # the anti-noise budget's ledger
  class SlackCard < ApplicationRecord
    include AgentScoped

    STATES = %w[posted suppressed failed].freeze

    belongs_to :proposal, class_name: "Concierge::AgentProposal",
                          foreign_key: :agent_proposal_id, inverse_of: false

    validates :state, inclusion: { in: STATES }

    scope :posted,     -> { where(state: "posted") }
    scope :suppressed, -> { where(state: "suppressed") }
    scope :failed,     -> { where(state: "failed") }
    scope :recent,     -> { order(created_at: :desc, id: :desc) }

    # Cards this agent actually put in Slack today. The window is the host's day,
    # not a rolling 24 hours: "how many times did this agent interrupt us today"
    # is the question an operator is really asking, and a rolling window makes the
    # answer depend on what time they ask.
    scope :posted_since, ->(time) { posted.where(posted_at: time..) }

    def self.posted_today(agent_slug, now: Time.current)
      where(agent_slug: agent_slug.to_s).posted_since(now.beginning_of_day)
    end

    # The thread every card for this case hangs off — one thread per case (§2.6),
    # where the case is the (agent, account) pair. The first card posted for a
    # scope *is* the thread; everything after it replies into that thread, so a
    # channel is a list of accounts rather than a firehose of individual actions.
    #
    # Scoped, so a thread can never be shared across agents or accounts: replying
    # a refund card into another account's thread would put one customer's
    # business in front of the wrong case.
    def self.thread_ts_for(scope)
      root = for_scope(scope).posted.where.not(message_ts: nil).order(:created_at, :id).first
      root && (root.thread_ts.presence || root.message_ts)
    end

    def posted?     = state == "posted"
    def suppressed? = state == "suppressed"
    def failed?     = state == "failed"

    # Addressable means "we can update this card in place when it is decided."
    def addressable? = posted? && channel_id.present? && message_ts.present?

    # The (Agent × Subject) pair this card was written under, re-resolved from
    # config. Nil when either side no longer resolves — an agent removed from the
    # config, a deleted account — which is inert data rather than an error.
    def scope
      Concierge::Scope.resolve(agent_slug: agent_slug, subject_id: subject_id)
    end
  end
end
