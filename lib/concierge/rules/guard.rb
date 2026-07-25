module Concierge
  class Rules
    # A rule that graduated from advice to invariant (design §10.2). An
    # +enforcement: "guard"+ rule carries a +predicate+ the engine evaluates
    # itself, so the policy holds whether or not the model felt like following it
    # — the difference between "we told it not to" and "it cannot."
    #
    # The predicate is declarative data, never code: a rule arrives from a Slack
    # correction through a background job, and +eval+ on that path would be a
    # remote code execution hole with a friendly name.
    #
    #   {
    #     "action_class" => "money.refund",       # omit for "any action"
    #     "deny_when" => {
    #       "amount_cents" => { "gt" => 5000 },
    #       "reason"       => { "present" => true }
    #     }
    #   }
    #
    # Every condition must hold for the action to be denied (AND). An empty or
    # absent +deny_when+ denies the whole action class, which is how "this agent
    # never issues refunds" is expressed.
    #
    # §10.6's Proposal::Execute re-checks guard rules at execution time; the
    # engine's one dispatchable action class today is the outbound message, and
    # Concierge::Outreach consults this before it sends.
    class Guard
      OPERATORS = %w[eq ne gt gte lt lte in matches present absent].freeze

      class << self
        def violates?(rule, action_class:, payload: {})
          new(rule.predicate).violates?(action_class: action_class, payload: payload)
        end
      end

      def initialize(predicate)
        @predicate = predicate || {}
      end

      def violates?(action_class:, payload: {})
        return false if @predicate.blank?
        return false unless action_class_matches?(action_class)

        conditions.all? { |path, test| matches?(value_at(payload, path), test) }
      end

      private

      def conditions
        @predicate["deny_when"] || @predicate[:deny_when] || {}
      end

      def action_class_matches?(action_class)
        declared = @predicate["action_class"] || @predicate[:action_class]
        declared.blank? || declared.to_s == action_class.to_s
      end

      # Dot paths so a nested payload can be addressed without the predicate
      # language growing a grammar: "order.total_cents".
      def value_at(payload, path)
        path.to_s.split(".").reduce(payload) do |current, key|
          break nil unless current.respond_to?(:[])

          current[key] || current[key.to_sym]
        end
      end

      def matches?(value, test)
        # A bare scalar is equality — the common case shouldn't need a wrapper.
        return value.to_s == test.to_s unless test.is_a?(Hash)

        test.all? { |operator, operand| compare(value, operator.to_s, operand) }
      end

      def compare(value, operator, operand)
        case operator
        when "eq"      then value.to_s == operand.to_s
        when "ne"      then value.to_s != operand.to_s
        when "gt"      then numeric(value) && numeric(value) >  operand.to_f
        when "gte"     then numeric(value) && numeric(value) >= operand.to_f
        when "lt"      then numeric(value) && numeric(value) <  operand.to_f
        when "lte"     then numeric(value) && numeric(value) <= operand.to_f
        when "in"      then Array(operand).map(&:to_s).include?(value.to_s)
        when "matches" then value.to_s.match?(Regexp.new(operand.to_s, Regexp::IGNORECASE))
        when "present" then value.present? == !!operand
        when "absent"  then value.blank? == !!operand
        else
          # An unknown operator must not silently pass — a typo'd predicate that
          # quietly stops guarding is worse than one that never worked.
          raise Concierge::Error,
                "unknown guard operator #{operator.inspect} (expected one of #{OPERATORS.inspect})"
        end
      end

      def numeric(value)
        return nil unless value.is_a?(Numeric) || value.to_s.match?(/\A-?\d+(\.\d+)?\z/)

        value.to_f
      end
    end
  end
end
