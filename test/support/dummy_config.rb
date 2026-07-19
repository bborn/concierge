module Concierge
  module Test
    # The canonical Concierge configuration for the dummy host app. Test setup
    # calls this after resetting config, so every test starts from the same
    # baseline (and can override afterward). Later phases extend it as new
    # boundaries land.
    def self.configure!
      Concierge.configure do |c|
        c.default_model = "claude-sonnet-4-5"
        c.chat_factory  = ->(model:, chat_record: nil) { FakeChat.current }

        c.account do
          subject_class Tenant
          grain :account
          attribute(:name) { |t| t.name }
          attribute(:plan) { |t| t.plan }
          scope(:users)    { |t| t.users }
        end
      end
    end
  end
end
