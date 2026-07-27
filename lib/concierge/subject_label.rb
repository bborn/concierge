module Concierge
  # What a subject is *called*, for a human reading the queue.
  #
  # Every engine surface names a subject by its key — `account#135` — which is
  # correct and unreadable. The operator staring at the approval queue knows
  # "Crossroads Commons"; the engine only ever knew the pair. This is the seam
  # where the host closes that gap, once, for every surface:
  #
  #   config.subject_label = ->(subject) { Property.find_by(id: subject.id)&.business_name }
  #
  # ## A caption, never a key
  #
  # Nothing in the engine may look a subject up *by* its label, match on it,
  # route on it, or authorize with it. `(subject_type, subject_id)` stays the one
  # and only key — see Concierge::Subject#key and SubjectScoped — and this module
  # deliberately offers no inverse: there is no `find_by_label`, and adding one
  # would turn host display text into an identifier a caller could forge.
  #
  # ## A caption cannot take the admin down
  #
  # A host's lambda runs against the host's own database, mid-render, on a screen
  # whose job is to show an operator what is waiting. So: unset, blank, or
  # raising all fall back to `"#{subject_type}##{subject_id}"`. A raise is logged
  # once per resolution — a genuine host bug should leave a trace, and a hundred
  # rows should not leave a hundred identical lines.
  #
  # ## One lookup per subject, not one per row
  #
  # The proposals screen renders many rows and most of them are the same handful
  # of accounts. A Resolver memoizes by subject key for its own lifetime, and the
  # admin gives each request exactly one (see Concierge::ApplicationHelper), so a
  # page of N rows over K distinct subjects calls the host K times, never N.
  module SubjectLabel
    # What the host's callable is handed. Deliberately *not* the host record and
    # deliberately not Concierge::Subject: the admin renders rows, and a row
    # carries the key pair and nothing else. The host does its own lookup, which
    # is the only party that knows how.
    #
    # +type+ is the grain the host opted into ("account" / "user"), not a class
    # name. +id+ is the string the row is keyed by.
    Ref = Struct.new(:type, :id) do
      alias_method :subject_type, :type
      alias_method :subject_id, :id

      # The pair, in the shape every Concierge table stores it.
      def key
        { subject_type: type, subject_id: id }
      end

      def to_s
        "#{type}##{id}"
      end
    end

    # Resolves labels for one unit of work (one request, one Slack card) and
    # remembers what it already asked.
    class Resolver
      def initialize(hook = Concierge.config.subject_label)
        @hook   = hook
        @cache  = {}
        @logged = false
      end

      # The label for a record carrying a subject key, falling back to the key.
      # Safe to call on anything with +subject_type+/+subject_id+ (every
      # SubjectScoped row) or a Concierge::Subject.
      #
      # +fallback+ overrides that key for the handful of call sites that were
      # already printing the pair in some other shape ("account 135", "account
      # #135") before this hook existed, and must keep printing exactly that for
      # a host which never sets one.
      def label_for(record, fallback: nil)
        type, id = pair(record)
        label(type, id, fallback: fallback)
      end

      # Just the host's label, or nil when there is no hook, it answered blank,
      # or it raised.
      def host_label_for(record)
        type, id = pair(record)
        host_label(type, id)
      end

      # The label for a bare key pair, falling back to the key.
      def label(type, id, fallback: nil)
        host_label(type, id) || fallback || key_of(type, id)
      end

      # The host's label for a bare key pair, or nil.
      def host_label(type, id)
        @cache.fetch([ type.to_s, id.to_s ]) { @cache[[ type.to_s, id.to_s ]] = resolve(type, id) }
      end

      private

      attr_reader :hook

      def key_of(type, id)
        "#{type}##{id}"
      end

      def resolve(type, id)
        return nil unless hook

        label = hook.call(Ref.new(type.to_s, id.to_s)).to_s
        label.strip.empty? ? nil : label
      rescue StandardError => e
        log_failure(type, id, e)
        nil
      end

      # Once per resolver, not once per row: a broken lambda on a hundred-row
      # queue is one bug, and a hundred identical warnings is how the trace of it
      # gets scrolled past.
      def log_failure(type, id, error)
        return if @logged

        @logged = true
        Concierge.logger&.warn(
          "[concierge] config.subject_label raised for #{key_of(type, id)} " \
          "(#{error.class}: #{error.message}) — falling back to the subject key"
        )
      end

      def pair(record)
        if record.respond_to?(:subject_type) && record.respond_to?(:subject_id)
          [ record.subject_type, record.subject_id ]
        elsif record.is_a?(Concierge::Subject)
          [ record.grain, record.id ]
        elsif record.respond_to?(:to_hash)
          hash = record.to_hash
          [ hash[:subject_type] || hash["subject_type"], hash[:subject_id] || hash["subject_id"] ]
        else
          raise ArgumentError, "cannot read a subject key off #{record.inspect}"
        end
      end
    end

    class << self
      # One-shot resolution, for callers that name a single subject (a Slack
      # card, a notifier line). A screen full of rows wants its own Resolver
      # instead, so the memoization has somewhere to live.
      def for(record, fallback: nil)
        Resolver.new.label_for(record, fallback: fallback)
      end

      def for_key(type, id, fallback: nil)
        Resolver.new.label(type, id, fallback: fallback)
      end

      def host_label_for(record)
        Resolver.new.host_label_for(record)
      end

      def host_label_for_key(type, id)
        Resolver.new.host_label(type, id)
      end
    end
  end
end
