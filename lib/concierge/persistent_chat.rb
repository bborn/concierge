require "delegate"

module Concierge
  # The host's persistent conversation, driven the way an online turn actually
  # needs it: the customer's question written down alongside the agent's answer.
  #
  # RubyLLM 1.16 splits chat persistence across *two* objects, and a caller that
  # holds only one of them silently keeps half a transcript:
  #
  #   * +ChatMethods#ask+, on the host's **AR chat record**, is what writes the
  #     user row (+add_message(role: :user, ...)+ → +messages_association.create!+)
  #     before delegating to the model.
  #   * the +before_message+/+after_message+ callbacks installed by +to_llm+, on
  #     the **RubyLLM::Chat**, are what write the *assistant* row.
  #
  # Concierge drives +to_llm+ — so every reply was persisted and no question ever
  # was. That is not merely an incomplete audit trail. +to_llm+ rebuilds the
  # in-memory thread from the persisted rows on the next turn, so turn 2 sent the
  # model its own previous answers with nothing they were answers *to*: a
  # monologue. And a thread whose first persisted message is an assistant turn is
  # rejected outright by Anthropic, which requires the first message to be a user
  # one — so a host's second turn on any proactively-opened thread was a live
  # 400 waiting to happen.
  #
  # The obvious repair — hand +Run+ the AR record, which carries the same fluent
  # surface — is the wrong one. +ChatMethods#with_instructions+ *persists the
  # system prompt as a message row*, and Concierge assembles that prompt fresh
  # every run out of the account's memories, the rules in force and a live
  # snapshot. Doing that would (a) copy the account's memory into the host's
  # customer-facing message store on every single turn, which is a retention and
  # privacy decision that belongs to the host (§10.12), and (b) be wrong even
  # ignoring privacy: +to_llm+ replays persisted system rows, so the next turn
  # would carry a stale prompt *alongside* the fresh one.
  #
  # So the two halves are split deliberately. Instructions stay in memory, where
  # they are rebuilt each run and nothing goes stale. The conversation — what was
  # asked and what was answered — goes to the host's table, which is where the
  # host already keeps the agent's replies.
  #
  # Only the default factory returns one of these. A host that supplies its own
  # +chat_factory+ owns its own persistence semantics, and a scripted double that
  # persists nothing keeps persisting nothing.
  class PersistentChat < SimpleDelegator
    # +chat+ is the record's +to_llm+ chat; +record+ is the host's AR chat.
    def initialize(chat, record)
      super(chat)
      @record = record
    end

    attr_reader :record

    # Write the customer's turn, then take the model's.
    #
    # Order matters: the delegate's in-memory thread was built from the rows that
    # existed *before* this call, so persisting first and asking second leaves the
    # row order and the message order identical. Persisting after the ask would
    # file the question behind the answer.
    def ask(message = nil, with: nil, &)
      persisted = persist_customer_turn(message, with)
      __getobj__.ask(message, with: with, &)
    rescue StandardError
      # The turn never happened, so the thread should look as it did before it.
      # Leaving the question behind would make the next turn re-ask it, and
      # RubyLLM's own AR path (+ChatMethods#complete+) cleans up after itself the
      # same way.
      destroy_quietly(persisted)
      raise
    end

    alias say ask

    # RubyLLM's +with_*+ builders return the chat for chaining. Hand back the
    # wrapper rather than the chat it wraps, so +chat.with_instructions(x).ask(y)+
    # still records the customer's turn instead of quietly dropping it.
    def method_missing(...)
      result = super
      result.equal?(__getobj__) ? self : result
    end

    def respond_to_missing?(...)
      super
    end

    private

    # Never fails the turn. A host message store that refuses a write is a
    # degraded transcript; swallowing the customer's answered question on top of
    # it would be the worse outcome, and the log says plainly what was lost.
    def persist_customer_turn(message, attachments)
      return unless @record.respond_to?(:add_message)

      @record.add_message(role: :user, content: content_for(message, attachments))
    rescue StandardError => e
      Concierge.logger&.warn(
        "[concierge] could not persist the customer's message: #{e.class}: #{e.message}"
      )
      nil
    end

    def content_for(message, attachments)
      return message if attachments.blank?

      RubyLLM::Content.new(message, attachments)
    end

    def destroy_quietly(record)
      record&.destroy
    rescue StandardError => e
      Concierge.logger&.warn(
        "[concierge] could not roll back the customer's message after a failed turn: " \
        "#{e.class}: #{e.message}"
      )
    end
  end
end
