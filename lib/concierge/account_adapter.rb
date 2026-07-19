module Concierge
  # Declarative mapping from a host's schema to Concierge's notion of a Subject.
  # Configured through a small block DSL:
  #
  #   config.account do
  #     subject_class Tenant
  #     grain :account
  #     attribute(:name) { |t| t.name }
  #     attribute(:plan) { |t| t.plan }
  #     scope(:users)    { |t| t.users }
  #   end
  #
  # The DSL setters double as readers when called without an argument/block, so
  # the runtime side (id_for, attribute_for, each_subject…) can read back what the
  # host declared.
  class AccountAdapter
    DEFAULT_ID = ->(record) { record.id }

    def initialize
      @grain        = :account
      @attributes   = {}
      @scopes       = {}
      @id_resolver  = DEFAULT_ID
      @each_source  = nil
      @find_source  = nil
    end

    # --- DSL (setter when given a value/block, reader otherwise) ---

    def subject_class(klass = nil)
      @subject_class = klass if klass
      @subject_class
    end

    def grain(value = nil)
      @grain = value.to_sym if value
      @grain
    end

    # How to derive a subject's id from its record. Defaults to #id.
    def id(&block)
      @id_resolver = block if block
      @id_resolver
    end

    # Map a named attribute to a lambda over the record.
    def attribute(name, &block)
      @attributes[name.to_sym] = block
    end

    # Map a named association to an account-scoped relation over the record.
    def scope(name, &block)
      @scopes[name.to_sym] = block
    end

    # Override enumeration (sweep source). The block receives a yielder:
    #   each { |&y| Tenant.active.find_each(&y) }
    # Defaults to +subject_class.find_each+.
    def each(&block)
      @each_source = block if block
      @each_source
    end

    # Override single-record lookup. Defaults to +subject_class.find(id)+.
    def find(&block)
      @find_source = block if block
      @find_source
    end

    # --- Runtime ---

    def attributes
      @attributes.keys
    end

    def id_for(record)
      @id_resolver.call(record)
    end

    def attribute_for(record, name)
      resolver = @attributes.fetch(name.to_sym) do
        raise Concierge::Error, "no attribute #{name.inspect} declared on the account adapter"
      end
      resolver.call(record)
    end

    def scope_for(record, name)
      resolver = @scopes.fetch(name.to_sym) do
        raise Concierge::Error, "no scope #{name.inspect} declared on the account adapter"
      end
      resolver.call(record)
    end

    # Wrap a host record as a Subject.
    def build(record)
      Subject.new(record, self)
    end

    # Resolve a Subject from its id.
    def find_subject(id)
      record = @find_source ? @find_source.call(id) : require_subject_class!.find(id)
      build(record)
    end

    # Yield every Subject — the source for proactive sweeps.
    def each_subject
      return enum_for(:each_subject) unless block_given?

      if @each_source
        @each_source.call { |record| yield build(record) }
      else
        require_subject_class!.find_each { |record| yield build(record) }
      end
    end

    private

    def require_subject_class!
      @subject_class || raise(Concierge::Error, "account adapter has no subject_class configured")
    end
  end
end
