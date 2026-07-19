module Concierge
  # A compact, deterministic view of one account's state, computed by evaluating
  # the Playbook's engagement signals against a Subject. Read at the start of
  # every run and included in the system prompt. Determinism matters: the
  # proactive change-gate and any caching compare snapshots, so the same data
  # must always render the same bytes.
  class Snapshot
    def self.for(subject, playbook: Concierge.config.playbook)
      new(subject, playbook)
    end

    def initialize(subject, playbook)
      @subject  = subject
      @playbook = playbook
    end

    # Ordered { signal_name => value } in Playbook registration order. Memoized,
    # and pure given fixed data. A signal that raises is captured inline so a bad
    # lambda can never crash a run.
    def to_h
      @to_h ||= signals.each_with_object({}) do |(name, lambda), acc|
        acc[name] = evaluate(lambda)
      end
    end

    # A stable multi-line block for prompt inclusion.
    def to_prompt
      lines = to_h.map { |name, value| "- #{name}: #{format_value(value)}" }
      ([ "Account state:" ] + lines).join("\n")
    end

    # A cheap fingerprint for change detection (Phase 7).
    def digest
      require "digest"
      Digest::SHA256.hexdigest(to_h.map { |k, v| "#{k}=#{v}" }.join("\n"))
    end

    private

    def signals
      @playbook ? @playbook.engagement_signals : {}
    end

    def evaluate(lambda)
      lambda.call(@subject)
    rescue => e
      "<error: #{e.message}>"
    end

    def format_value(value)
      case value
      when true  then "yes"
      when false then "no"
      when nil   then "unknown"
      else value.to_s
      end
    end
  end
end
