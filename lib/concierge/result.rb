module Concierge
  # The structured outcome of a run. Never a raw exception — a failed run returns
  # a Result whose #ok? is false and whose #error carries the RubyLLM error.
  class Result
    attr_reader :reply_text, :tool_calls, :input_tokens, :output_tokens, :model, :error

    # The rules the agent said it applied, and the ones it cited that were never
    # in its prompt (design §10.4). +rule_ids_applied+ is the model's claim;
    # +unknown_rule_ids+ is that claim cross-checked against what we injected.
    attr_reader :rule_ids_applied, :unknown_rule_ids

    # The provenance row written for this run, when one was.
    attr_reader :run_record

    def initialize(reply_text: nil, tool_calls: [], input_tokens: nil,
                   output_tokens: nil, model: nil, error: nil, suppressed: false,
                   rule_ids_applied: [], unknown_rule_ids: [], run_record: nil)
      @reply_text       = reply_text
      @tool_calls       = tool_calls || []
      @input_tokens     = input_tokens
      @output_tokens    = output_tokens
      @model            = model
      @error            = error
      @suppressed       = suppressed
      @rule_ids_applied = rule_ids_applied || []
      @unknown_rule_ids = unknown_rule_ids || []
      @run_record       = run_record
    end

    def self.failure(error, model: nil)
      new(model: model, error: error)
    end

    # A run that was intentionally not performed (e.g. a human holds the thread,
    # or governance suppressed it). Used from Phase 6/7/8.
    def self.suppressed(reason: nil)
      new(reply_text: reason, suppressed: true)
    end

    def ok?
      @error.nil? && !@suppressed
    end

    def suppressed?
      @suppressed
    end

    def total_tokens
      (input_tokens || 0) + (output_tokens || 0)
    end
  end
end
