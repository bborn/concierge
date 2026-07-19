require "test_helper"

module Concierge
  class MemoryTest < ActiveSupport::TestCase
    setup do
      @tenant = Tenant.create!(name: "Acme", plan: "pro")
      @subject = Concierge.config.account.build(@tenant)
    end

    test "for_subject scopes by grain and id" do
      mine = Memory.create!(subject_type: "account", subject_id: @tenant.id.to_s, body: "hi")
      other = Memory.create!(subject_type: "account", subject_id: "999", body: "nope")

      rows = Memory.for_subject(@subject)
      assert_includes rows, mine
      refute_includes rows, other
    end

    test "a blank body persists — no presence-validation trap (§6)" do
      row = Memory.new(subject_type: "account", subject_id: @tenant.id.to_s, body: "")
      assert row.save, "expected a blank-body memory to save"
    end

    test "tier and source are validated" do
      row = Memory.new(subject_type: "account", subject_id: "1", tier: "bogus")
      refute row.valid?
      assert_includes row.errors.attribute_names, :tier
    end
  end
end
