module Concierge
  class Proposal
    # Where the engine's authority ends and the host's begins (design §10.6,
    # §10.8). An action class the engine does not own needs a **host-provided
    # executor** — a callable the host registers — and may declare a
    # **precondition** the engine re-validates before dispatching to it.
    #
    #   Concierge.configure do |c|
    #     c.proposals do
    #       execute "record.update" do |proposal, scope|
    #         scope.subject.to_model.update!(proposal.action_arguments)
    #       end
    #
    #       precondition("record.update") { |scope| { plan: scope.subject[:plan] } }
    #     end
    #   end
    #
    # Registration is by exact action class, by prefix (+"record.*"+), or by
    # +"*"+ for everything. Most specific wins, so a host can register a blanket
    # audit executor and then override one class.
    #
    # The host executor is **not** the engine's guarantee. §10.8 is explicit: the
    # engine's job is to hand an approved, maker-checked, precondition-valid
    # proposal to a callable. The callable re-checks its own domain invariants —
    # OfferLab's +Orders::IssueRefund+ still enforces "refunds only originate from
    # a human", independently, so even a bug in this class cannot issue one.
    class Registry
      WILDCARD = "*".freeze

      # The one action class the engine dispatches itself: an outbound message,
      # through the existing Outreach/Channel path (§10.6). Registered as a
      # prefix so a host can still override one exact class (+"message.outreach"+)
      # without losing the rest.
      #
      # It raises rather than returning false on a non-delivery so the *reason*
      # lands on the row — "no channel could reach this account" and "the channel
      # errored" are different operator problems.
      MESSAGE_EXECUTOR = lambda do |proposal, scope|
        status = Concierge::Outreach.dispatch(
          scope, proposal.action_arguments, channel: proposal.channel, kind: proposal.kind
        )
        raise Concierge::Error, "delivery returned #{status.inspect}" unless status == :delivered

        true
      end

      # What an outbound message assumes about the world: the customer's own
      # standing instruction about being contacted. If they opt out — or ask for
      # less — between the draft and the approval, the draft is stale, and
      # executing it anyway would override the one preference that is theirs and
      # not ours. Frequency caps and quiet hours are deliberately *not* in here:
      # those bound autonomous volume, and a human explicitly approving this
      # message is the thing they exist to defer to.
      MESSAGE_PRECONDITION = lambda do |scope|
        preference = Concierge::OutreachPreference.for(scope)
        { "opted_out" => !!preference.opted_out, "frequency" => preference.frequency }
      end

      def initialize
        @executors     = { "message.#{WILDCARD}" => MESSAGE_EXECUTOR }
        @preconditions = { "message.#{WILDCARD}" => MESSAGE_PRECONDITION }
      end

      # Register the callable that performs an action class — or, called bare,
      # read back the one registered for exactly that pattern. Same setter/reader
      # rule as every other block in the config DSL.
      def execute(action_class, callable = nil, &block)
        pattern = action_class.to_s
        @executors[pattern] = callable || block if callable || block
        @executors[pattern]
      end

      # Register (or read) what this action class assumed about the world. The
      # engine digests the result at propose time and re-digests it at execution;
      # a mismatch fails the execution rather than acting on stale assumptions.
      #
      # The callable takes the Scope, and optionally the payload when the
      # precondition depends on *which* record is being touched.
      def precondition(action_class, callable = nil, &block)
        pattern = action_class.to_s
        @preconditions[pattern] = callable || block if callable || block
        @preconditions[pattern]
      end

      def executor_for(action_class)
        lookup(@executors, action_class)
      end

      def precondition_for(action_class)
        lookup(@preconditions, action_class)
      end

      def action_classes
        @executors.keys
      end

      private

      # Exact match, then the longest matching prefix, then +"*"+. Longest-prefix
      # rather than first-registered so registration order cannot change which
      # executor runs — that would be a very quiet way to send a refund through
      # the wrong callable.
      def lookup(table, action_class)
        key = action_class.to_s
        return table[key] if table.key?(key)

        prefixed = table.keys.select do |pattern|
          pattern.end_with?(".#{WILDCARD}") && key.start_with?(pattern.delete_suffix(WILDCARD))
        end
        return table[prefixed.max_by(&:length)] if prefixed.any?

        table[WILDCARD]
      end
    end
  end
end
