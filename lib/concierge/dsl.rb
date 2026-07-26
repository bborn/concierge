module Concierge
  # The one rule behind every config block: a declared name is a setter when
  # called with a value or a block, and a reader when called bare. So the same
  # method both configures and reads back:
  #
  #   config.playbook do
  #     goals "Get each account to publish."   # writes
  #   end
  #   config.playbook.goals                    # reads
  #
  # The second rule, which every collection in the config surface has to obey:
  # a declaration is **total, not cumulative**. Saying the same thing twice says
  # it once. A host's +Concierge.configure+ lives in its initializer, which Rails
  # re-runs inside +to_prepare+ on *every* code reload in development, while the
  # memoized Configuration survives the reload (the gem is not reloadable). So a
  # collection that appends grows one more copy of the host's whole declaration
  # per reload — see Capability::Registry#register and Playbook#account_types,
  # which key on identity rather than piling up.
  module DSL
    # +name(value)+ writes, +name+ reads. An optional block coerces on write.
    def dsl_value(name, &coerce)
      define_method(name) do |value = nil|
        unless value.nil?
          instance_variable_set(:"@#{name}", coerce ? coerce.call(value) : value)
        end
        instance_variable_get(:"@#{name}")
      end
    end

    # +name { ... }+ stores the block, +name+ reads it back.
    def dsl_block(name)
      define_method(name) do |&block|
        instance_variable_set(:"@#{name}", block) if block
        instance_variable_get(:"@#{name}")
      end
    end
  end
end
