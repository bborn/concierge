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
    include ActiveJob::TestHelper

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
      proposal = Concierge::AgentProposal.create!(**csm.key, action_class: "record.update",
                                                  gate: "human_approval", idempotency_key: "k1")
      Concierge::AgentRule.create!(**csm.key, body: "a rule", state: "active")
      Concierge::AgentRun.create!(**csm.key, trigger: "reactive", status: "ok")

      Concierge::SlackCard.create!(**csm.key, agent_proposal_id: proposal.id, state: "posted",
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

    test "a handback ends one cell's takeover and attributes it to that cell only" do
      # Releasing re-enables autonomous proactive sends for the pair it names, so
      # it has to stop at that pair in both dimensions — and the name on it has to
      # land on that row and no other.
      @grid.each_value { |scope| Concierge::Handoff.seize!(scope, operator: "sam") }

      Concierge::Handoff.active_for(@grid[[ :csm, :acme ]]).release!(by: "dana@acme.test")

      @grid.each do |(agent_slug, account), scope|
        handoff = Concierge::Handoff.for_scope(scope).sole

        if [ agent_slug, account ] == [ :csm, :acme ]
          assert handoff.released?, "the released cell is still holding the thread"
          assert_equal "dana@acme.test", handoff.released_by
        else
          assert handoff.active?, "#{agent_slug}/#{account} lost its takeover to another cell's handback"
          assert_nil handoff.released_by,
                     "#{agent_slug}/#{account} was attributed another cell's handback"
        end
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

    test "one idempotency key proposed from every cell stages four proposals, not one" do
      # The dedupe lookup is a read path like any other and must not cross either
      # dimension. A host that derives its key from a domain id —
      # "plan-change-#{order_id}" — proposes the same key from more than one cell
      # as a matter of course; a global lookup hands the later callers the first
      # cell's row and never stages their action at all, so a human never sees it.
      Concierge.configure { |c| c.agent(:csm) { authority { action "record.update", :human_approval } } }

      staged = @grid.to_h do |cell, scope|
        agent_slug, account = cell
        [ cell, Concierge::Proposal.propose(
          scope, action_class: "record.update", idempotency_key: "plan-change-4471",
                 payload: { "note" => "for #{agent_slug}/#{account}" }
        ) ]
      end

      assert_equal 4, staged.values.map(&:id).uniq.size,
                   "a colliding idempotency key deduped across the grid"
      @grid.each do |cell, scope|
        rows = Concierge::AgentProposal.for_scope(scope)

        assert_equal 1, rows.count, "#{cell.inspect} saw #{rows.count} proposals"
        assert_equal staged[cell].id, rows.sole.id,
                     "#{cell.inspect} was handed another cell's proposal"
        assert_equal "for #{cell.first}/#{cell.last}", rows.sole.payload["note"]
      end
    end

    test "idempotency still holds inside a cell, where the key actually means something" do
      Concierge.configure { |c| c.agent(:csm) { authority { action "record.update", :human_approval } } }
      scope = @grid[[ :csm, :acme ]]

      first  = Concierge::Proposal.propose(scope, action_class: "record.update",
                                                  idempotency_key: "plan-change-4471")
      second = Concierge::Proposal.propose(scope, action_class: "record.update",
                                                  idempotency_key: "plan-change-4471")

      assert_equal first.id, second.id
      assert_equal 1, Concierge::AgentProposal.count
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

    test "an execution deferred to a job performs into its own cell and no other" do
      # A Slack approval now hands the *doing* to Concierge::ProposalExecutionJob,
      # so an execution crosses a process boundary carrying a bare proposal id
      # (§10.7). The job holds no scope of its own — it re-resolves the (agent,
      # account) pair from the row — which is what keeps a queue from becoming a
      # way to point one cell's execution at a neighbour.
      transport = Concierge::Test.configure_slack!(channels: { billing: "C0BILLING" })
      acme   = @grid[[ :billing, :acme ]]
      globex = @grid[[ :billing, :globex ]]
      [ acme, globex ].each do |scope|
        Concierge::Outreach.deliver(
          Concierge::Result.new(reply_text: "note for #{scope.subject.id}"), scope, channel: :in_app
        )
      end
      acme_row = Concierge::AgentProposal.for_scope(acme).sole

      Concierge::Slack::Intake.handle(approve_click(acme_row))
      # Nothing has been performed yet — that is the point of the split — and the
      # neighbour has not been touched by the click either.
      assert_equal "approved", acme_row.reload.state
      assert_equal 0, Concierge::ChannelDelivery.for_scope(acme).count
      assert_equal "proposed", Concierge::AgentProposal.for_scope(globex).sole.state
      # The "something is queued" marker the admin queue reads is a row write like
      # any other, so it is scoped like any other: one click marks one cell.
      assert acme_row.execution_queued?
      refute Concierge::AgentProposal.for_scope(globex).sole.execution_queued?,
             "queueing one cell's execution marked a neighbour's row as queued"

      perform_enqueued_jobs

      assert_equal "executed", acme_row.reload.state
      assert_equal 1, Concierge::ChannelDelivery.for_scope(acme).count
      assert_equal 0, Concierge::ChannelDelivery.for_scope(globex).count,
                   "a queued execution delivered into the neighbouring account"
      assert_equal 0, Concierge::ChannelDelivery.for_scope(@grid[[ :csm, :acme ]]).count,
                   "a queued billing execution was audited under the CSM"
      assert_equal "proposed", Concierge::AgentProposal.for_scope(globex).sole.state,
                   "a queued execution decided another cell's proposal"
      refute acme_row.reload.execution_queued?, "the row still promises a run that already happened"
      # And the card it redrew afterwards went back to its own agent's channel.
      assert_equal [ "C0BILLING" ], transport.calls_to("chat.update").map { |call| call.payload[:channel] }.uniq
    end

    test "a retry deferred to a job re-attempts its own cell and no other" do
      # A deferred *retry* is a second way for one cell's work to cross a process
      # boundary as a bare proposal id (§10.7) — and it starts from a row that has
      # already failed once, so getting the wrong one would re-attempt a
      # neighbour's action nobody asked to be re-attempted. The job re-resolves the
      # (agent, account) pair from the row; it carries no scope of its own.
      acme   = @grid[[ :billing, :acme ]]
      globex = @grid[[ :billing, :globex ]]
      [ acme, globex ].each do |scope|
        Concierge::Outreach.deliver(
          Concierge::Result.new(reply_text: "note for #{scope.subject.id}"), scope, channel: :in_app
        )
      end
      # Both cells are approved and both failed the same way — the case where a
      # retry aimed at one could plausibly land on the other.
      rows = { acme: Concierge::AgentProposal.for_scope(acme).sole,
               globex: Concierge::AgentProposal.for_scope(globex).sole }
      rows.each_value do |row|
        row.update_columns(state: "approved", approved_by: "sam@acme.test",
                           approved_at: Time.current, execution_error: "the API was down",
                           execution_failed_at: Time.current)
      end

      Concierge::ApprovalIntake.retry_execution(rows[:acme], by: "sam@acme.test", execute: false)
      Concierge::ProposalExecutionJob.perform_now(rows[:acme].id, by: "sam@acme.test")

      assert_equal "executed", rows[:acme].reload.state
      assert_equal 1, Concierge::ChannelDelivery.for_scope(acme).count
      assert_equal 0, Concierge::ChannelDelivery.for_scope(globex).count,
                   "a queued retry re-attempted into the neighbouring account"
      assert_equal 0, Concierge::ChannelDelivery.for_scope(@grid[[ :csm, :acme ]]).count,
                   "a queued billing retry was audited under the CSM"
      # The neighbour's failure is untouched: it was never cleared, so nothing in
      # the engine will re-attempt it on its own.
      globex_row = rows[:globex].reload
      assert_equal "approved", globex_row.state
      assert globex_row.execution_failed?, "a retry of one cell cleared another cell's failure"
      refute globex_row.execution_queued?
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

    # Slot 3 is the dimension the whole grid rests on: an agent's tool scope is
    # what decides which rows it can reach at all. The host declares it in an
    # initializer that runs inside +to_prepare+, which re-runs on every Rails
    # code reload while the memoized Configuration survives it — so "the host
    # said this again" must never mean "the agent may do this twice" (#4998).
    test "re-running the host's config leaves every cell's tool scope untouched" do
      before = @grid.keys.to_h { |cell| [ cell, tools_handed_to_the_model(cell) ] }

      3.times { Concierge::Test.configure_agents! }

      @grid.each_key do |cell|
        after = tools_handed_to_the_model(cell)

        assert_equal before[cell], after,
                     "#{cell.inspect}'s tool scope changed when the initializer re-ran"
        assert_equal after.uniq, after, "#{cell.inspect} was handed a duplicate tool"
      end

      # ...and the two agents are still as far apart as they were: billing reads
      # and writes its own notes and nothing else, however many times the host's
      # initializer has run.
      assert_equal %w[recall remember], tools_handed_to_the_model([ :billing, :acme ])
      assert_includes tools_handed_to_the_model([ :csm, :acme ]), "set_outreach_preference"
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

    # The offline path used to keep the grid apart by holding nothing: with no
    # credentials there was no persisted Chat to key by at all, so the question was
    # only whether every cell got the same nil. It now persists — a keyless host
    # gets a real conversation per cell (task 5017) — which turns a degrade with no
    # state into a second full set of host chats written by a path the credentialed
    # tests never take. That is a new place for the boundary to leak, so the grid
    # asks the same question of it that it asks of the online path.
    test "the uncredentialed path gives every cell its own chat, and no neighbour's" do
      chats = without_provider_credentials do
        @grid.transform_values { |scope| Concierge::ChatResolver.call(scope) }
      end

      assert_equal 4, chats.values.compact.map(&:id).uniq.size,
                   "two cells were handed the same Chat with no credentials"
      assert_equal 4, Concierge::Conversation.count

      @grid.each do |(agent_slug, account), scope|
        conversations = Concierge::Conversation.for_scope(scope)

        assert_equal 1, conversations.count,
                     "#{agent_slug}/#{account} did not own exactly one offline conversation"
        assert_equal chats[[ agent_slug, account ]].id, conversations.first.chat_id,
                     "#{agent_slug}/#{account} was pointed at another cell's offline chat"
      end
    end

    test "an uncredentialed run keeps every cell's prompt and provenance its own" do
      without_provider_credentials do
        @grid.each do |(agent_slug, account), scope|
          Concierge::Test::FakeChat.script(reply: "offline reply for #{agent_slug}/#{account}")
          result = Concierge::Run.reactive(scope, "hi")

          assert result.ok?, "#{agent_slug}/#{account} could not run offline"
          assert_equal "offline reply for #{agent_slug}/#{account}", result.reply_text
        end
      end

      chat_ids = @grid.to_h do |cell, scope|
        [ cell, Concierge::AgentRun.for_scope(scope).first&.chat_id ]
      end

      assert_equal 4, chat_ids.values.compact.uniq.size,
                   "two offline runs recorded the same host chat"

      @grid.each do |(agent_slug, account), scope|
        runs = Concierge::AgentRun.for_scope(scope)

        assert_equal 1, runs.count, "#{agent_slug}/#{account} saw #{runs.count} runs"
        assert_equal Concierge::Conversation.for_scope(scope).first.chat_id, runs.first.chat_id,
                     "an offline run recorded a chat belonging to another cell"
      end

      # Each cell's memory is still only its own — the degrade did not widen any
      # scope on the way past.
      @grid.each do |(agent_slug, account), scope|
        assert_equal [ "private note for #{agent_slug}/#{account}" ],
                     Concierge::Memory.for_scope(scope).map(&:body)
      end
    end

    # ...and with a host whose offline factory actually *writes* the turn down,
    # the words themselves must land in the right cell. This is the same crossing
    # the online transcript test guards, asked of the path a keyless host takes,
    # because that path now writes customer questions into a host message store
    # too. The factory is the demo host's own — not a double written for this
    # test — so what is under test is the code the offline server really runs.
    test "an uncredentialed turn writes its words into its own cell's chat and no other" do
      Concierge.config.chat_factory = lambda do |model:, chat_record: nil|
        Dummy::ScriptedChat.new(chat_record)
      end

      without_provider_credentials do
        @grid.each do |(agent_slug, account), scope|
          Concierge::Run.reactive(scope, "secret question from #{agent_slug}/#{account}")
        end
      end

      @grid.each do |(agent_slug, account), scope|
        run = Concierge::AgentRun.for_scope(scope).first

        assert_equal "secret question from #{agent_slug}/#{account}", run.prompt_text
        assert_equal run.chat_id, run.prompt_message.chat_id,
                     "#{agent_slug}/#{account}'s question landed in another cell's chat"

        # The thread replayed into this cell's next prompt holds this cell's words
        # only — a keyless host is still a host with a conversation to protect.
        asked = Concierge.chat_model.find(run.chat_id).messages.where(role: "user").pluck(:content)
        assert_equal [ "secret question from #{agent_slug}/#{account}" ], asked
      end
    end

    # Both tests above inherit the dummy's default_provider and so never touch the
    # model registry at all: a host that names its provider assumes the model
    # exists. A host that leaves default_provider nil — documented and supported —
    # puts the whole resolution on the model lookup, and that lookup goes to
    # whichever registry RubyLLM memoized: the host's own `models` table once
    # acts_as_model has a row in it, holding only the models this host has already
    # talked to. Every other model reads as unknown there, which used to switch the
    # offline degrade off entirely (task 5014) and now, with the resolution ours,
    # would fail the resolution instead — mid-grid, after the first cells had
    # already written their AgentRun rows, leaving the grid half populated by a
    # path nobody chose.
    #
    # So this is the same isolation question asked in the one configuration where
    # the lookup is load-bearing.
    test "a partial registry leaves every cell resolvable, and still its own" do
      Concierge.config.default_provider = nil

      with_partial_model_registry("gpt-4.1-nano" => "openai") do
        without_provider_credentials do
          chats = @grid.transform_values do |scope|
            assert_nothing_raised { Concierge::ChatResolver.call(scope) }
          end

          assert_equal 4, chats.values.compact.map(&:id).uniq.size,
                       "a cell was handed another cell's chat under a partial registry"

          @grid.each do |(agent_slug, account), scope|
            Concierge::Test::FakeChat.script(reply: "offline reply for #{agent_slug}/#{account}")
            result = Concierge::Run.reactive(scope, "hi")

            assert result.ok?, "#{agent_slug}/#{account} could not run offline: #{result.error.inspect}"
            assert_equal "offline reply for #{agent_slug}/#{account}", result.reply_text
          end
        end
      end

      assert_equal 4, Concierge::Conversation.count

      @grid.each do |(agent_slug, account), scope|
        runs = Concierge::AgentRun.for_scope(scope)

        assert_equal 1, runs.count, "#{agent_slug}/#{account} saw #{runs.count} runs"
        assert_equal Concierge::Conversation.for_scope(scope).first.chat_id, runs.first.chat_id,
                     "a run under a partial registry recorded another cell's chat"
        assert_equal [ "private note for #{agent_slug}/#{account}" ],
                     Concierge::Memory.for_scope(scope).map(&:body)
      end
    end

    # Credentials coming back must not merge cells either: two agents over one
    # account still get two conversations — the same two they had offline, now
    # continued rather than replaced.
    test "credentials returning still yields one conversation per (agent, account)" do
      offline = without_provider_credentials do
        @grid.transform_values { |scope| Concierge::ChatResolver.call(scope).id }
      end

      chat_ids = @grid.transform_values { |scope| Concierge::ChatResolver.call(scope).id }

      assert_equal offline, chat_ids, "a cell's offline thread was abandoned when the key came back"
      assert_equal 4, chat_ids.values.uniq.size, "two cells were handed the same Chat"
      assert_equal 4, Concierge::Conversation.count
      @grid.each do |(agent_slug, account), scope|
        assert_equal 1, Concierge::Conversation.for_scope(scope).count,
                     "#{agent_slug}/#{account} did not own exactly one conversation"
      end
    end

    # A run row can now point at the reply the agent gave, so that an operator can
    # spot-check a citation against what was actually said. That pointer is a new
    # way out of the cell: resolve it carelessly — by id against the host's whole
    # message table — and one agent's audit screen shows another agent's, or
    # another account's, conversation. So it is resolved *through the run's own
    # chat*, and this is the test that says so.
    test "a run's reply resolves inside its own cell and nowhere else" do
      Concierge.config.chat_factory = persisting_chat_factory

      runs = @grid.to_h do |(agent_slug, account), scope|
        record = with_model_reply("private reply for #{agent_slug}/#{account}") do
          Concierge::Run.reactive(scope, "hi")
        end.run_record
        [ [ agent_slug, account ], record ]
      end

      # Four turns, four chats, four replies — none shared.
      assert_equal 4, runs.values.map(&:chat_id).uniq.size, "two cells shared a chat"
      assert_equal 4, runs.values.map(&:message_id).uniq.compact.size, "two cells shared a reply"

      runs.each do |(agent_slug, account), run|
        assert_equal "private reply for #{agent_slug}/#{account}", run.reply_text
        assert_equal run.chat_id, run.reply_message.chat_id,
                     "#{agent_slug}/#{account} read a message from another cell's chat"
      end
    end

    # The engine now writes the *customer's* turn into the host's message store
    # too, which is a second crossing of the same boundary and a worse one to get
    # wrong: a reply is the agent's own words, but a question is the customer's.
    # Four cells asking four different things must produce four sealed threads —
    # if the write picked the wrong chat, Acme's question would be sitting in
    # Globex's conversation and would be replayed into Globex's next prompt.
    test "a customer's question is written into its own cell's chat and no other" do
      Concierge.config.chat_factory = persisting_chat_factory

      runs = @grid.to_h do |(agent_slug, account), scope|
        record = with_model_reply("reply for #{agent_slug}/#{account}") do
          Concierge::Run.reactive(scope, "secret question from #{agent_slug}/#{account}")
        end.run_record
        [ [ agent_slug, account ], record ]
      end

      assert_equal 4, runs.values.map(&:prompt_message_id).uniq.compact.size,
                   "two cells shared a customer message"

      runs.each do |(agent_slug, account), run|
        assert_equal "secret question from #{agent_slug}/#{account}", run.prompt_text
        assert_equal run.chat_id, run.prompt_message.chat_id,
                     "#{agent_slug}/#{account}'s question landed in another cell's chat"

        # ...and the thread that gets replayed into this cell's next prompt holds
        # this cell's words only.
        asked = Concierge.chat_model.find(run.chat_id).messages.where(role: "user").pluck(:content)
        assert_equal [ "secret question from #{agent_slug}/#{account}" ], asked
      end
    end

    test "a run pointed at a neighbour's question reads nothing rather than their words" do
      Concierge.config.chat_factory = persisting_chat_factory

      mine = with_model_reply("reply for csm/acme") do
        Concierge::Run.reactive(@grid[[ :csm, :acme ]], "what Acme asked")
      end.run_record
      theirs = with_model_reply("reply for billing/globex") do
        Concierge::Run.reactive(@grid[[ :billing, :globex ]], "what Globex asked")
      end.run_record

      mine.update!(prompt_message_id: theirs.prompt_message_id)

      assert_nil mine.reload.prompt_message, "a run reached into another cell's chat"
      assert_nil mine.prompt_text
      assert_equal :pruned, mine.prompt_unavailable_reason
    end

    test "a run pointed at a neighbour's message reads nothing rather than their words" do
      Concierge.config.chat_factory = persisting_chat_factory

      mine = with_model_reply("private reply for csm/acme") do
        Concierge::Run.reactive(@grid[[ :csm, :acme ]], "hi")
      end.run_record
      theirs = with_model_reply("private reply for billing/globex") do
        Concierge::Run.reactive(@grid[[ :billing, :globex ]], "hi")
      end.run_record

      # However the pointer came to be wrong — a bad backfill, a reused id after a
      # host prune, a bug — it must fail closed.
      mine.update!(message_id: theirs.message_id)

      assert_nil mine.reload.reply_message, "a run reached into another cell's chat"
      assert_nil mine.reply_text
      assert_equal :pruned, mine.reply_unavailable_reason
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

    def approve_click(row)
      card = Concierge::SlackCard.find_by(agent_proposal_id: row.id)
      {
        "type" => "block_actions", "user" => { "id" => "U9" }, "trigger_id" => "T1",
        "container" => { "channel_id" => card&.channel_id, "message_ts" => card&.message_ts },
        "actions" => [ { "action_id" => Concierge::Slack::Card::APPROVE, "value" => row.id.to_s } ]
      }
    end

    # What +chat.with_tools+ was actually given for this cell — the real path
    # through Run#attach_tools, not the registry read on its own.
    def tools_handed_to_the_model(cell)
      Concierge::Test::FakeChat.script(reply: "ok")
      chat = Concierge::Test::FakeChat.current
      Concierge::Run.reactive(@grid[cell], "hi")
      chat.tools.map(&:name)
    end

    def subject_for(tenant)
      tenant.users.create!(email: "user@#{tenant.name.downcase}.test")
      Concierge.config.account.build(tenant)
    end
  end
end
