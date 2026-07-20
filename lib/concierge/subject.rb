module Concierge
  # A thin, uniform wrapper around a host record (a Tenant, an Account, a User…)
  # so the rest of the gem never touches host classes directly. Everything it
  # exposes is resolved through the AccountAdapter the host configured.
  class Subject
    attr_reader :record, :adapter

    def initialize(record, adapter)
      @record  = record
      @adapter = adapter
    end

    # The stable identifier for this subject, per the adapter's +id+ resolver.
    def id
      adapter.id_for(record)
    end

    # The underlying host record (for callers that legitimately need it, e.g. a
    # tool building an account-scoped query).
    def to_model
      record
    end

    # The column pair every Concierge table keys a subject by. One rule, so no
    # model, store, or query has to spell out the (grain, id) stringification.
    def key
      { subject_type: grain.to_s, subject_id: id.to_s }
    end

    # :account or :user — the grain the host opted into.
    def grain
      adapter.grain
    end

    # A host-derived attribute (name, plan, …) via the adapter's mapping lambda.
    def attribute(name)
      adapter.attribute_for(record, name)
    end
    alias [] attribute

    # An account-scoped relation for +name+ (e.g. :users, :reports). This is the
    # only sanctioned way a tool reaches associated data — it can never widen past
    # this subject.
    def scope_for(name)
      adapter.scope_for(record, name)
    end

    # Identity is (grain + id) — two Subjects wrapping the same record are equal.
    def ==(other)
      other.is_a?(Subject) && other.grain == grain && other.id == id
    end
    alias eql? ==

    def hash
      [ grain, id ].hash
    end

    def to_s
      "#<Concierge::Subject #{grain}##{id}>"
    end
  end
end
