require "test_helper"

module Concierge
  # THE load-bearing invariant of Phase 10 (design §10.12): the cross-account
  # isolation test is now a cross-(agent, account) test. No query may escape
  # either dimension.
  #
  # The grid is 2 agents × 2 accounts = 4 private namespaces, plus the reserved
  # shared one. Every assertion below is "this cell sees itself and nothing else
  # it should not."
  class ScopeIsolationTest < ActiveSupport::TestCase
    setup do
      Concierge::Test.configure_agents!

      @acme   = subject_for(Tenant.create!(name: "Acme",   plan: "pro"))
      @globex = subject_for(Tenant.create!(name: "Globex", plan: "enterprise"))

      @grid = {
        [ :csm,     :acme ]   => Concierge::Scope.new(agent(:csm),     @acme),
        [ :csm,     :globex ] => Concierge::Scope.new(agent(:csm),     @globex),
        [ :billing, :acme ]   => Concierge::Scope.new(agent(:billing), @acme),
        [ :billing, :globex ] => Concierge::Scope.new(agent(:billing), @globex)
      }

      @store = Concierge::ContextStore.new
      @grid.each do |(agent_slug, account), scope|
        @store.remember(scope, body: "private note for #{agent_slug}/#{account}")
      end
    end

    test "a Scope key carries both dimensions" do
      scope = @grid[[ :billing, :acme ]]

      assert_equal({ agent_slug: "billing", subject_type: "account",
                     subject_id: @acme.id.to_s },
                   scope.key)
    end

    test "two Scopes are equal only when agent AND subject match" do
      assert_equal @grid[[ :csm, :acme ]], Concierge::Scope.new(agent(:csm), @acme)
      refute_equal @grid[[ :csm, :acme ]], @grid[[ :billing, :acme ]]
      refute_equal @grid[[ :csm, :acme ]], @grid[[ :csm, :globex ]]
      assert_equal 4, @grid.values.uniq.size
    end

    test "every cell of the (agent x account) grid sees exactly its own row" do
      @grid.each do |(agent_slug, account), scope|
        rows = Concierge::Memory.for_scope(scope)

        assert_equal 1, rows.count, "#{agent_slug}/#{account} saw #{rows.count} rows"
        assert_equal "private note for #{agent_slug}/#{account}", rows.first.body
      end
    end

    test "no query escapes the agent dimension" do
      csm_bodies     = @store.top_of_mind(@grid[[ :csm, :acme ]]).map(&:body)
      billing_bodies = @store.top_of_mind(@grid[[ :billing, :acme ]]).map(&:body)

      refute_includes csm_bodies,     "private note for billing/acme"
      refute_includes billing_bodies, "private note for csm/acme"
    end

    test "no query escapes the account dimension" do
      acme_bodies = @store.top_of_mind(@grid[[ :csm, :acme ]]).map(&:body)

      refute_includes acme_bodies, "private note for csm/globex"
      assert_equal 0, Concierge::Memory.for_scope(@grid[[ :csm, :globex ]])
                                       .where("body LIKE '%acme%'").count
    end

    test "recall reaches neither dimension's neighbours" do
      bodies = @store.recall(@grid[[ :csm, :acme ]], query: "private note").map(&:body)

      assert_equal [ "private note for csm/acme" ], bodies
    end

    test "a soft-delete cannot reach across either dimension" do
      other = Concierge::Memory.for_scope(@grid[[ :billing, :acme ]]).first

      assert_nil @store.forget(@grid[[ :csm, :acme ]], other.id)
      assert other.reload.active, "a CSM forget retired a billing row"
    end

    test "the shared namespace is readable by every agent and owned by none" do
      @store.remember(@grid[[ :csm, :acme ]], body: "Acme is an EU entity", shared: true)

      assert_includes @store.top_of_mind(@grid[[ :csm, :acme ]]).map(&:body),
                      "Acme is an EU entity"
      assert_includes @store.top_of_mind(@grid[[ :billing, :acme ]]).map(&:body),
                      "Acme is an EU entity"

      # ...but only for that account, and it is in neither agent's own space.
      refute_includes @store.top_of_mind(@grid[[ :csm, :globex ]]).map(&:body),
                      "Acme is an EU entity"
      refute_includes Concierge::Memory.for_scope(@grid[[ :csm, :acme ]]).map(&:body),
                      "Acme is an EU entity"
    end

    test "sharing is opt-in: an ordinary write stays private" do
      @store.remember(@grid[[ :billing, :acme ]], body: "card on file expires in March")

      refute_includes @store.top_of_mind(@grid[[ :csm, :acme ]]).map(&:body),
                      "card on file expires in March"
    end

    test "a tool bound to a scope writes only inside that namespace" do
      scope = @grid[[ :billing, :acme ]]
      tool  = Concierge::Tools::RememberTool.new(subject: @acme, scope: scope)

      tool.execute(body: "invoice #42 is disputed")

      assert_includes Concierge::Memory.for_scope(scope).map(&:body), "invoice #42 is disputed"
      refute_includes Concierge::Memory.for_scope(@grid[[ :csm, :acme ]]).map(&:body),
                      "invoice #42 is disputed"
      refute_includes Concierge::Memory.for_scope(@grid[[ :billing, :globex ]]).map(&:body),
                      "invoice #42 is disputed"
    end

    test "routines are per (agent, account) too" do
      csm     = @grid[[ :csm, :acme ]]
      billing = @grid[[ :billing, :acme ]]

      Concierge::Tools::RoutineTool.new(subject: @acme, scope: csm)
                                   .execute(action: "create", schedule: "0 9 * * 1",
                                            instruction: "weekly activation nudge")

      assert_equal 1, Concierge::Routine.for_scope(csm).count
      assert_equal 0, Concierge::Routine.for_scope(billing).count
      assert_equal 0, Concierge::Routine.for_scope(@grid[[ :csm, :globex ]]).count
    end

    test "handoffs, conversations, deliveries, proposals, rules and runs all carry the pair" do
      csm     = @grid[[ :csm, :acme ]]
      billing = @grid[[ :billing, :acme ]]

      Concierge::Handoff.seize!(csm, operator: "sam")
      Concierge::Governance.new.record!(csm, channel: "email")
      Concierge::ChatResolver.call(csm)
      Concierge::AgentProposal.create!(**csm.key, action_class: "record.update",
                                       gate: "human_approval", idempotency_key: "k1")
      Concierge::AgentRule.create!(**csm.key, body: "a rule", state: "active")
      Concierge::AgentRun.create!(**csm.key, trigger: "reactive", status: "ok")

      Concierge::SlackCard.create!(**csm.key, agent_proposal_id: 1, state: "posted",
                                   channel_id: "C0CSM", message_ts: "1.1", posted_at: Time.current)

      [ Concierge::Handoff, Concierge::ChannelDelivery, Concierge::Conversation,
        Concierge::AgentProposal, Concierge::AgentRule, Concierge::AgentRun,
        Concierge::SlackCard ].each do |model|
        assert_equal 1, model.for_scope(csm).count,   "#{model} lost the CSM's row"
        assert_equal 0, model.for_scope(billing).count,
                     "#{model} leaked the CSM's row into billing"
        assert_equal 0, model.for_scope(@grid[[ :csm, :globex ]]).count,
                     "#{model} leaked Acme's row into Globex"
      end
    end

    test "every cell's proposals are its own, and nothing else's" do
      @grid.each do |(agent_slug, account), scope|
        Concierge::AgentProposal.create!(
          **scope.key, action_class: "record.update", gate: "human_approval",
          idempotency_key: "#{agent_slug}-#{account}",
          payload: { "note" => "proposed for #{agent_slug}/#{account}" }
        )
      end

      @grid.each do |(agent_slug, account), scope|
        rows = Concierge::AgentProposal.for_scope(scope)

        assert_equal 1, rows.count, "#{agent_slug}/#{account} saw #{rows.count} proposals"
        assert_equal "proposed for #{agent_slug}/#{account}", rows.sole.payload["note"]
      end
    end

    test "approving one cell's proposal executes into that cell and no other" do
      # :billing gates on both accounts, so both stage rather than send.
      acme   = @grid[[ :billing, :acme ]]
      globex = @grid[[ :billing, :globex ]]
      [ acme, globex ].each do |scope|
        Concierge::Outreach.deliver(
          Concierge::Result.new(reply_text: "note for #{scope.subject.id}"), scope, channel: :in_app
        )
      end

      Concierge::ApprovalIntake.approve(Concierge::AgentProposal.for_scope(acme).sole,
                                        by: "sam@acme.test")

      assert_equal 1, Concierge::ChannelDelivery.for_scope(acme).count
      assert_equal 0, Concierge::ChannelDelivery.for_scope(globex).count,
                   "approving Acme's proposal delivered to Globex"
      assert_equal 0, Concierge::ChannelDelivery.for_scope(@grid[[ :csm, :acme ]]).count,
                   "a billing approval was audited under the CSM"
      assert_equal "proposed", Concierge::AgentProposal.for_scope(globex).sole.state,
                   "approving one cell's proposal decided another's"
    end

    test "a guard rule blocks execution only inside the cell that owns it" do
      acme   = @grid[[ :billing, :acme ]]
      globex = @grid[[ :billing, :globex ]]
      [ acme, globex ].each do |scope|
        Concierge::Outreach.deliver(
          Concierge::Result.new(reply_text: "we guarantee it"), scope, channel: :in_app
        )
      end

      rule = Concierge::Rules.propose(
        acme, body: "Never put the word guarantee in a customer email.",
              enforcement: "guard", author: "a",
              predicate: { "action_class" => Concierge::Authority::MESSAGE_OUTREACH,
                           "deny_when" => { "body" => { "matches" => "guarantee" } } }
      )
      Concierge::Rules.activate!(rule, by: "sam")

      assert_equal :blocked_by_rule,
                   Concierge::ApprovalIntake.approve(Concierge::AgentProposal.for_scope(acme).sole,
                                                     by: "sam@acme.test")
      assert_equal :executed,
                   Concierge::ApprovalIntake.approve(Concierge::AgentProposal.for_scope(globex).sole,
                                                     by: "sam@acme.test")
    end

    test "every cell's Slack cards are its own, and nothing else's" do
      # The Slack seam adds a second surface onto the same rows, so it doubles the
      # isolation surface again (§10.12). A card that leaked across either dimension
      # would be a disclosure bug: it would put one account's business — or one
      # business function's — in front of the wrong channel.
      transport = Concierge::Test.configure_slack!(
        channels: { csm: "C0CSM", billing: "C0BILLING" }
      )
      Concierge.configure { |c| c.agent(:csm) { authority { action "record.update", :human_approval } } }

      @grid.each do |(agent_slug, account), scope|
        Concierge::Proposal.propose(scope, action_class: "record.update",
                                           payload: { "note" => "for #{agent_slug}/#{account}" },
                                           idempotency_key: "#{agent_slug}-#{account}")
      end

      @grid.each do |(agent_slug, account), scope|
        cards = Concierge::SlackCard.for_scope(scope)

        assert_equal 1, cards.count, "#{agent_slug}/#{account} saw #{cards.count} cards"
        assert_equal agent_slug.to_s, cards.sole.agent_slug
        assert_equal Concierge.config.slack.channel(agent_slug), cards.sole.channel_id,
                     "#{agent_slug}/#{account}'s card went to another agent's channel"
      end

      # Each agent's cards went only to its own channel, across both accounts.
      posted = transport.calls_to("chat.postMessage").group_by { |call| call.payload[:channel] }
      assert_equal 2, posted["C0CSM"].size
      assert_equal 2, posted["C0BILLING"].size
    end

    test "a case thread is per (agent, account) and shared with no other cell" do
      transport = Concierge::Test.configure_slack!
      Concierge.configure { |c| c.agent(:csm) { authority { action "record.update", :human_approval } } }

      # Two proposals per cell: the second must reply into *its own* cell's thread.
      @grid.each do |(agent_slug, account), scope|
        2.times do |index|
          Concierge::Proposal.propose(scope, action_class: "record.update",
                                             payload: { "note" => "#{agent_slug}/#{account}/#{index}" },
                                             idempotency_key: "#{agent_slug}-#{account}-#{index}")
        end
      end

      threads = @grid.transform_values { |scope| Concierge::SlackCard.thread_ts_for(scope) }

      assert_equal 4, threads.values.compact.uniq.size, "two cells shared one Slack thread"
      @grid.each do |cell, scope|
        cards = Concierge::SlackCard.for_scope(scope)

        assert_equal 2, cards.count
        assert_equal [ threads[cell] ], cards.map(&:thread_ts).uniq,
                     "#{cell.inspect} posted into a thread that is not its own"
      end
      assert_empty transport.calls_to("chat.postMessage").select { |call|
        call.payload[:thread_ts] && !threads.values.include?(call.payload[:thread_ts])
      }, "a card replied into a thread belonging to no cell"
    end

    test "the daily card cap is counted per agent, not across all of them" do
      # An agent-wide count would let one busy business function mute another's
      # approvals — the cap crossing the agent boundary is the same leak in a
      # different costume.
      Concierge::Test.configure_slack!(cap: 1)
      Concierge.configure { |c| c.agent(:csm) { authority { action "record.update", :human_approval } } }

      @grid.each do |(agent_slug, account), scope|
        Concierge::Proposal.propose(scope, action_class: "record.update",
                                           payload: { "note" => "#{agent_slug}/#{account}" },
                                           idempotency_key: "#{agent_slug}-#{account}")
      end

      assert_equal 1, Concierge::SlackCard.posted_today(:csm).count
      assert_equal 1, Concierge::SlackCard.posted_today(:billing).count
      # ...and the two that were capped are still awaiting a human, in their own cells.
      assert_equal 2, Concierge::SlackCard.suppressed.count
      assert_equal 4, Concierge::AgentProposal.awaiting.count
    end

    test "a Slack thread reply lands in its own cell's memory and nobody else's" do
      Concierge::Test.configure_slack!
      billing = @grid[[ :billing, :acme ]]
      Concierge::Proposal.propose(billing, action_class: "record.update",
                                           payload: { "note" => "n" }, idempotency_key: "b-a")
      card = Concierge::SlackCard.for_scope(billing).sole

      Concierge::Slack::Intake.handle_event(
        { "type" => "event_callback",
          "event" => { "type" => "message", "channel" => card.channel_id,
                       "thread_ts" => card.thread_ts, "user" => "U9",
                       "text" => "Their CFO wants this in writing." } }
      )

      assert_includes Concierge::Memory.for_scope(billing).map(&:body),
                      "Their CFO wants this in writing."
      [ [ :csm, :acme ], [ :billing, :globex ], [ :csm, :globex ] ].each do |cell|
        refute_includes Concierge::Memory.for_scope(@grid[cell]).map(&:body),
                        "Their CFO wants this in writing.",
                        "a Slack thread reply leaked into #{cell.inspect}"
      end
    end

    test "every cell's rules are its own, and nothing else's" do
      # Rules are the one table whose subject keys may be null (a rule can be
      # agent-wide), which makes it the easiest place for the agent dimension to
      # leak. Assert the grid cell by cell like every other table.
      @grid.each do |(agent_slug, account), scope|
        activate(scope, "Rule for #{agent_slug} about #{account} specifically.")
      end

      @grid.each do |(agent_slug, account), scope|
        bodies = Concierge::Rules.active_for(scope).map(&:body)

        assert_equal [ "Rule for #{agent_slug} about #{account} specifically." ], bodies,
                     "#{agent_slug}/#{account} saw #{bodies.inspect}"
      end
    end

    test "an agent-wide rule crosses accounts but never the agent boundary" do
      wide = Concierge::Rules.propose(@grid[[ :csm, :acme ]],
                                      body: "Never promise a delivery date.",
                                      applies_to: :agent, author: "a")
      Concierge::Rules.activate!(wide, by: "sam")

      # By design it reaches every account this agent serves...
      [ [ :csm, :acme ], [ :csm, :globex ] ].each do |cell|
        assert_includes Concierge::Rules.active_for(@grid[cell]).map(&:id), wide.id
      end
      # ...and no account of any other agent.
      [ [ :billing, :acme ], [ :billing, :globex ] ].each do |cell|
        refute_includes Concierge::Rules.active_for(@grid[cell]).map(&:id), wide.id,
                        "an agent-wide rule leaked into another agent"
      end
    end

    test "there is no shared namespace for rules" do
      # §10.3's `_shared` exists for facts every agent legitimately reads. An
      # *instruction* that crosses agents is the contamination this phase prevents,
      # so a rule written into the shared namespace is readable by nobody.
      Concierge::AgentRule.create!(**@grid[[ :csm, :acme ]].shared_key,
                                   body: "Never mention the roadmap.", state: "active")

      @grid.each_value do |scope|
        refute_includes Concierge::Rules.active_for(scope).map(&:body), "Never mention the roadmap."
      end
    end

    test "guard rules bind only the agent that owns them" do
      rule = Concierge::Rules.propose(
        @grid[[ :billing, :acme ]],
        body: "Never put the word guarantee in a customer email.",
        enforcement: "guard", author: "a",
        predicate: { "action_class" => Concierge::Authority::MESSAGE_OUTREACH,
                     "deny_when" => { "body" => { "matches" => "guarantee" } } }
      )
      Concierge::Rules.activate!(rule, by: "sam")

      assert_equal 1, Concierge::Rules.guard_violations(@grid[[ :billing, :acme ]],
                                                        action_class: "message.outreach",
                                                        payload: { body: "we guarantee it" }).size
      [ [ :csm, :acme ], [ :billing, :globex ], [ :csm, :globex ] ].each do |cell|
        assert_empty Concierge::Rules.guard_violations(@grid[cell],
                                                       action_class: "message.outreach",
                                                       payload: { body: "we guarantee it" }),
                     "a guard rule bound #{cell.inspect}"
      end
    end

    test "run provenance is keyed by the pair, so an audit cannot pull in a neighbour" do
      @grid.each do |(agent_slug, account), scope|
        Concierge::Test::FakeChat.script(reply: "reply for #{agent_slug}/#{account}")
        Concierge::Run.reactive(scope, "hi")
      end

      @grid.each do |(agent_slug, account), scope|
        runs = Concierge::AgentRun.for_scope(scope)

        assert_equal 1, runs.count, "#{agent_slug}/#{account} saw #{runs.count} runs"
        assert_equal agent_slug.to_s, runs.first.agent_slug
      end
    end

    test "for_subject resolves the default agent rather than widening to all of them" do
      # The §10.9 shim. Widening the oldest scope in the codebase to "every
      # agent" would be the leak this whole phase exists to prevent.
      assert_equal [ "private note for csm/acme" ],
                   Concierge::Memory.for_subject(@acme).map(&:body)
    end

    test "a row written with no namespace belongs to the default agent" do
      row = Concierge::Memory.create!(**@acme.key, body: "legacy note")

      assert_equal "csm", row.agent_slug
      assert_includes Concierge::Memory.for_scope(@grid[[ :csm, :acme ]]).map(&:body), "legacy note"
      refute_includes Concierge::Memory.for_scope(@grid[[ :billing, :acme ]]).map(&:body), "legacy note"
    end

    test "an un-scoped tool still keys by the default agent and this subject" do
      Concierge::Tools::RememberTool.new(subject: @acme).execute(body: "unscoped note")

      assert_includes Concierge::Memory.for_scope(@grid[[ :csm, :acme ]]).map(&:body), "unscoped note"
      [ [ :billing, :acme ], [ :csm, :globex ], [ :billing, :globex ] ].each do |cell|
        refute_includes Concierge::Memory.for_scope(@grid[cell]).map(&:body), "unscoped note"
      end
    end

    test "outreach preferences deliberately have no agent dimension" do
      # One customer, one answer to "how often may we contact you" (§10.1).
      Concierge::OutreachPreference.for(@grid[[ :csm, :acme ]]).update!(frequency: "less")

      assert_equal "less", Concierge::OutreachPreference.for(@grid[[ :billing, :acme ]]).frequency
      assert_equal "normal", Concierge::OutreachPreference.for(@grid[[ :csm, :globex ]]).frequency
      refute Concierge::OutreachPreference.column_names.include?("agent_slug")
    end

    private

    def activate(scope, body)
      rule = Concierge::Rules.propose(scope, body: body, author: "drafter")
      Concierge::Rules.activate!(rule, by: "sam")
      rule
    end

    def agent(slug)
      Concierge.config.agent(slug)
    end

    def subject_for(tenant)
      tenant.users.create!(email: "user@#{tenant.name.downcase}.test")
      Concierge.config.account.build(tenant)
    end
  end
end
