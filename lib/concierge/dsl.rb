module Concierge
  # The one rule behind every config block: a declared name is a setter when
  # called with a value or a block, and a reader when called bare. So the same
  # method both configures and reads back:
  #
  #   config.playbook do
  #     goals "Get each account to publish."   # writes
  #   end
  #   config.playbook.goals                    # reads
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
