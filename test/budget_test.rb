require "test_helper"

module Concierge
  class BudgetTest < ActiveSupport::TestCase
    setup do
      @tenant  = Tenant.create!(name: "Acme", plan: "pro")
      @subject = Concierge.config.account.build(@tenant)
    end

    test "no budget configured means never exhausted" do
      Concierge.config.budget = nil
      Concierge::Budget.new.spend!(@subject, 10_000)
      refute Concierge::Budget.new.exhausted?(@subject)
    end

    test "per-tenant cap exhausts after enough spend" do
      Concierge.config.budget = { per_tenant: 100, global: 1_000_000 }
      budget = Concierge::Budget.new

      refute budget.exhausted?(@subject)
      budget.spend!(@subject, 150)
      assert budget.exhausted?(@subject)
    end

    test "a per-account override raises the cap but the global rail still binds" do
      Concierge.config.budget = { per_tenant: 100, global: 200 }
      Concierge.config.budget_override_for = ->(_s) { 10_000 }
      budget = Concierge::Budget.new

      budget.spend!(@subject, 150)         # above per_tenant (100), under override + global
      refute budget.exhausted?(@subject), "override should lift the per-account cap"

      budget.spend!(@subject, 60)          # global now 210 > 200 rail
      assert budget.exhausted?(@subject), "global rail must still bind"
    end
  end
end
