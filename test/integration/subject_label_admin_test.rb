require "test_helper"

# Every engine surface that names a subject, named the same way.
#
# The defect this covers: a staged proposal read `renewals · account#135`, and so
# did the runs, memories, routines, deliveries, rules, agents and Slack screens —
# correct internally and unreadable to the operator the queue is for. One host
# hook now answers for all of them, so the fix cannot be half-applied and stay
# green.
class SubjectLabelAdminTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  # Every admin screen that prints a subject identity. Adding a screen that
  # names a subject and not adding it here is the failure mode this list exists
  # to make loud.
  SCREENS = %w[proposals runs memories routines deliveries rules agents slack].freeze

  # Back-compat is byte-for-byte, and one screen never used the canonical key:
  # the agents screen's last-handback line has always read `account 1`, with a
  # space, inside a <code>. A host that sets no hook must still see exactly that,
  # so that call site passes its own wording as the fallback.
  SPACED_KEY_SCREENS = %w[agents].freeze

  setup do
    Concierge::Test.configure_agents!
    Concierge.config.authenticate_admin = ->(_c) { true }
    Concierge.config.admin_actor        = ->(_c) { "sam@acme.test" }
    @transport = Concierge::Test.configure_slack!

    @tenant = Tenant.create!(name: "Crossroads Commons", plan: "pro")
    @tenant.users.create!(email: "dana@crossroads.test")
    @subject = Concierge.config.account.build(@tenant)
    @key     = { subject_type: "account", subject_id: @tenant.id.to_s }
    @csm     = Concierge::Scope.new(Concierge.config.agent(:csm), @subject)
    @billing = Concierge::Scope.new(Concierge.config.agent(:billing), @subject)

    populate_every_surface
  end

  test "unset, every surface names the subject by its key exactly as it did before" do
    SCREENS.each do |screen|
      get "/concierge/admin/#{screen}"

      assert_response :success
      assert_includes response.body, key_on(screen),
                      "#{screen} stopped printing the subject key with no hook configured"
    end
  end

  test "set, every surface names the subject by the host's label" do
    Concierge.config.subject_label = ->(subject) { Tenant.find_by(id: subject.id)&.name }

    SCREENS.each do |screen|
      get "/concierge/admin/#{screen}"

      assert_response :success
      assert_includes response.body, "Crossroads Commons",
                      "#{screen} still names the subject by its key"
      refute_includes response.body, key_on(screen),
                      "#{screen} still prints the raw key beside the label"
    end
  end

  test "the run detail page names the subject too" do
    Concierge.config.subject_label = ->(_subject) { "Crossroads Commons" }
    run = Concierge::AgentRun.order(:id).last

    get "/concierge/admin/runs/#{run.id}"

    assert_response :success
    assert_includes response.body, "Crossroads Commons"
    refute_includes response.body, "account##{@tenant.id}"
  end

  test "a label that returns nothing leaves every surface on the key" do
    Concierge.config.subject_label = ->(_subject) { "" }

    SCREENS.each do |screen|
      get "/concierge/admin/#{screen}"

      assert_response :success
      assert_includes response.body, key_on(screen), "#{screen} lost its fallback"
    end
  end

  test "a raising label leaves every surface on the key, and no screen 500s" do
    Concierge.config.subject_label = ->(_subject) { raise "the host's Property lookup is broken" }

    SCREENS.each do |screen|
      get "/concierge/admin/#{screen}"

      assert_response :success, "#{screen} let a broken caption take the admin down"
      assert_includes response.body, key_on(screen)
    end
  end

  test "a label carrying markup renders inert" do
    # Host-supplied text in the engine's own HTML. ERB escapes by default and
    # nothing on this path may reach for html_safe/raw.
    Concierge.config.subject_label = ->(_subject) { "<script>alert('x')</script> Bell & Co" }

    SCREENS.each do |screen|
      get "/concierge/admin/#{screen}"

      assert_response :success
      refute_includes response.body, "<script>alert('x')</script>", "#{screen} rendered live markup"
      assert_includes response.body, "&lt;script&gt;alert(&#39;x&#39;)&lt;/script&gt; Bell &amp; Co"
    end
  end

  test "no view on this path reaches for html_safe or raw" do
    # A belt-and-braces guard on the *source*, because the assertion above only
    # proves today's templates: a later edit that wraps the label in raw would
    # not be caught by any screen that happens to have no other subject on it.
    Dir[Concierge::Engine.root.join("app/views/concierge/admin/**/*.erb")].each do |path|
      Pathname.new(path).read.scan(/^.*subject_label.*$/).each do |line|
        refute_match(/html_safe|\braw\(/, line, "#{path} made a host-supplied label trusted HTML")
      end
    end
  end

  test "a hundred rows over three accounts asks the host three times, not a hundred" do
    # The queue renders many rows and most of them are the same handful of
    # accounts. A naive per-row callable turns one page into a hundred host
    # queries; the resolver is memoized by subject key for the life of the
    # request, so this is bounded by *distinct subjects on the page*.
    tenants = [ @tenant, Tenant.create!(name: "Bell Yards", plan: "pro"),
                Tenant.create!(name: "Union Depot", plan: "free") ]
    100.times do |i|
      tenant = tenants[i % 3]
      Concierge::ChannelDelivery.create!(subject_type: "account", subject_id: tenant.id.to_s,
                                         agent_slug: "csm", channel: "email", kind: "outreach",
                                         sent_at: Time.current)
    end

    asked = []
    Concierge.config.subject_label = ->(subject) { asked << subject.id; Tenant.find_by(id: subject.id)&.name }

    queries = count_queries { get "/concierge/admin/deliveries" }

    assert_response :success
    assert_equal 3, asked.size, "the host was asked once per row instead of once per subject"
    assert_equal 3, asked.uniq.size
    assert_operator queries, :<, 20,
                    "rendering 100+ rows issued #{queries} queries — the label lookup is per-row"
    tenants.each { |t| assert_includes response.body, t.name }
  end

  test "one request's labels do not leak into the next" do
    Concierge.config.subject_label = ->(_subject) { "First Answer" }
    get "/concierge/admin/deliveries"
    assert_includes response.body, "First Answer"

    Concierge.config.subject_label = ->(_subject) { "Second Answer" }
    get "/concierge/admin/deliveries"

    assert_includes response.body, "Second Answer"
    refute_includes response.body, "First Answer"
  end

  private

  # What this screen prints for a subject when no hook is configured.
  def key_on(screen)
    SPACED_KEY_SCREENS.include?(screen) ? "account #{@tenant.id}" : "account##{@tenant.id}"
  end

  def count_queries(&block)
    count = 0
    counter = ->(_name, _start, _finish, _id, payload) do
      count += 1 unless payload[:name] == "SCHEMA" || payload[:sql].start_with?("TRANSACTION")
    end
    ActiveSupport::Notifications.subscribed(counter, "sql.active_record", &block)
    count
  end

  # One row on each of the eight screens, all naming the same account.
  def populate_every_surface
    Concierge::Memory.create!(**@key, agent_slug: "csm", body: "prefers a quarterly review",
                              source: "agent")
    Concierge::ChannelDelivery.create!(**@key, agent_slug: "csm", channel: "email",
                                       kind: "outreach", sent_at: Time.current)
    Concierge::Routine.create!(**@key, agent_slug: "csm", schedule: "0 9 * * 1",
                               instruction: "check the renewal", author: "agent")
    Concierge::AgentRun.create!(**@key, agent_slug: "csm", trigger: "reactive", status: "ok")

    rule = Concierge::Rules.propose(@csm, body: "Never quote a date without checking.",
                                          author: "agent:csm")
    Concierge::Rules.activate!(rule, by: "sam@acme.test")
    Concierge::Rules.propose(@csm, body: "Always greet by first name.", author: "agent:csm")

    # The agents screen names a subject only on the last handback line.
    Concierge::Handoff.seize!(@csm, operator: "support@acme.test")
    Concierge::Handoff.active_for(@csm).release!(by: "dana@crossroads.test")

    # A proposal, which is also what puts a card on the Slack screen.
    perform_enqueued_jobs do
      Concierge::Proposal.propose(@billing, action_class: "record.plan_change",
                                            payload: { "from" => "pro", "to" => "enterprise" },
                                            idempotency_key: "plan-1")
    end
  end
end
