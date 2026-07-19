require "test_helper"

class AdapterTest < ActiveSupport::TestCase
  setup do
    @tenant = Tenant.create!(name: "Acme", plan: "pro")
  end

  test "find_subject returns a Subject wrapping the right record" do
    subject = Concierge.config.account.find_subject(@tenant.id)

    assert_kind_of Concierge::Subject, subject
    assert_equal @tenant, subject.to_model
    assert_equal @tenant.id, subject.id
    assert_equal :account, subject.grain
  end

  test "attribute lambdas return host-derived values" do
    subject = Concierge.config.account.build(@tenant)

    assert_equal "Acme", subject.attribute(:name)
    assert_equal "pro", subject[:plan]
  end

  test "unknown attribute raises a clear error" do
    subject = Concierge.config.account.build(@tenant)

    error = assert_raises(Concierge::Error) { subject.attribute(:nope) }
    assert_match(/no attribute :nope/, error.message)
  end

  test "each_subject enumerates every account (sweep source)" do
    Tenant.create!(name: "Beta", plan: "free")

    ids = Concierge.config.account.each_subject.map(&:id)

    assert_equal Tenant.pluck(:id).sort, ids.sort
  end

  test "scope_for returns an account-scoped relation" do
    mine = @tenant.users.create!(email: "me@acme.test")
    other = Tenant.create!(name: "Beta").users.create!(email: "them@beta.test")

    subject = Concierge.config.account.build(@tenant)
    users = subject.scope_for(:users)

    assert_includes users, mine
    refute_includes users, other
  end

  test ":user grain opt-in resolves a user subject" do
    user = @tenant.users.create!(email: "u@acme.test")

    adapter = Concierge::AccountAdapter.new
    adapter.instance_eval do
      subject_class User
      grain :user
      attribute(:email) { |u| u.email }
      scope(:tenant) { |u| User.where(tenant_id: u.tenant_id) }
    end

    subject = adapter.find_subject(user.id)

    assert_equal :user, subject.grain
    assert_equal user, subject.to_model
    assert_equal "u@acme.test", subject.attribute(:email)
  end

  test "Subjects wrapping the same record are equal" do
    a = Concierge.config.account.build(@tenant)
    b = Concierge.config.account.find_subject(@tenant.id)

    assert_equal a, b
    assert_equal 1, [ a, b ].uniq.size
  end
end
