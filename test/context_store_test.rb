require "test_helper"

module Concierge
  class ContextStoreTest < ActiveSupport::TestCase
    setup do
      @store   = Concierge::ContextStore.new
      @tenant  = Tenant.create!(name: "Acme", plan: "pro")
      @subject = Concierge.config.account.build(@tenant)
    end

    test "remember then recall round-trips by category" do
      @store.remember(@subject, body: "prefers weekly digests", category: "preference")
      @store.remember(@subject, body: "on pro plan", category: "billing")

      prefs = @store.recall(@subject, category: "preference")
      assert_equal [ "prefers weekly digests" ], prefs.map(&:body)
    end

    test "recall matches a keyword query" do
      @store.remember(@subject, body: "loves the changelog feature")
      @store.remember(@subject, body: "never opened reports")

      hits = @store.recall(@subject, query: "changelog")
      assert_equal [ "loves the changelog feature" ], hits.map(&:body)
    end

    test "recall orders pinned ahead of recent" do
      @store.remember(@subject, body: "old but pinned", pinned: true)
      @store.remember(@subject, body: "newer, unpinned")

      assert_equal "old but pinned", @store.recall(@subject).first.body
    end

    test "forget soft-deactivates: row retained, excluded from recall" do
      row = @store.remember(@subject, body: "temporary note")
      @store.forget(@subject, row.id)

      assert Memory.exists?(row.id), "row should be retained"
      refute_includes @store.recall(@subject).map(&:id), row.id
      refute row.reload.active
    end

    test "top_of_mind weights human-authored memory ahead of agent" do
      @store.remember(@subject, body: "agent guess", source: :agent)
      @store.remember(@subject, body: "operator correction", source: :human)

      assert_equal "operator correction", @store.top_of_mind(@subject).first.body
    end

    test "two-tier retrieval at :user grain merges account + subject memory" do
      user = @tenant.users.create!(email: "u@acme.test")
      user_adapter = Concierge::AccountAdapter.new
      user_adapter.instance_eval do
        subject_class User
        grain :user
        attribute(:email) { |u| u.email }
      end
      user_subject = user_adapter.build(user)

      @store.remember(@subject, body: "account-wide fact", tier: :account)
      @store.remember(user_subject, body: "user-private fact", tier: :subject)

      bodies = @store.top_of_mind(user_subject, account_scope: @subject).map(&:body)
      assert_includes bodies, "account-wide fact"
      assert_includes bodies, "user-private fact"
    end

    test "blank body does not raise inside the store" do
      assert_nothing_raised { @store.remember(@subject, body: "") }
    end
  end
end
