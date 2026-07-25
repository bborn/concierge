require "fugit"

module Concierge
  # A recurring instruction for the agent, authored by the agent OR the customer
  # ("once a week send me this report"). A single static sweep enqueues due rows
  # — no per-account cron (design §3.6, research constraint #6).
  class Routine < ApplicationRecord
    include AgentScoped

    AUTHORS = %w[agent customer].freeze

    validates :schedule, :instruction, presence: true
    validates :author, inclusion: { in: AUTHORS }
    validate  :schedule_parses

    scope :enabled, -> { where(enabled: true) }
    scope :due, ->(now = Time.current) { enabled.where(next_run_at: ..now) }

    before_validation :ensure_next_run_at, on: :create

    def due?(now = Time.current)
      enabled? && next_run_at.present? && next_run_at <= now
    end

    # Advance to the next fire time after +from+.
    def advance!(from = Time.current)
      update!(next_run_at: parsed_schedule&.next_time(from)&.to_t)
    end

    private

    # Returns a schedulable Fugit object (cron or natural language) — anything
    # that can produce a next fire time. A bare duration ("5m") is not
    # schedulable and is treated as invalid.
    def parsed_schedule
      parsed = Fugit.parse(schedule)
      parsed.respond_to?(:next_time) ? parsed : nil
    rescue StandardError
      nil
    end

    def ensure_next_run_at
      self.next_run_at ||= parsed_schedule&.next_time&.to_t
    end

    def schedule_parses
      errors.add(:schedule, "is not a valid cron/duration") if schedule.present? && parsed_schedule.nil?
    end
  end
end
