module Concierge
  # The structured outcome of a run. Never a raw exception — a failed run returns
  # a Result whose #ok? is false and whose #error carries the RubyLLM error.
  class Result
    attr_reader :reply_text, :tool_calls, :input_tokens, :output_tokens, :model, :error

    def initialize(reply_text: nil, tool_calls: [], input_tokens: nil,
                   output_tokens: nil, model: nil, error: nil, suppressed: false)
      @reply_text    = reply_text
      @tool_calls    = tool_calls || []
      @input_tokens  = input_tokens
      @output_tokens = output_tokens
      @model         = model
      @error         = error
      @suppressed    = suppressed
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
