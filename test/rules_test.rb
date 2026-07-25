require "test_helper"

module Concierge
  # The rule lifecycle (design §10.2). The load-bearing property here is the gate:
  # **no rule goes active without a human tap, and never by the agent itself.**
  class RulesTest < ActiveSupport::TestCase
    setup do
      Concierge::Test.configure_agents!
      @tenant = Tenant.create!(name: "Acme", plan: "pro")
      @tenant.users.create!(email: "dana@acme.test")
      @subject = Concierge.config.account.build(@tenant)
      @csm     = Concierge::Scope.new(Concierge.config.agent(:csm), @subject)
      @billing = Concierge::Scope.new(Concierge.config.agent(:billing), @subject)
    end

    # --- propose -------------------------------------------------------------

    test "a proposed rule is not in force" do
      rule = Rules.propose(@csm, body: "Never quote a delivery date.", author: "dana@acme.test")

      assert rule.proposed?
      assert_equal 1, rule.version
      assert_empty Rules.active_for(@csm)
    end

    test "propose scopes to this subject by default, and can go wider" do
      mine  = Rules.propose(@csm, body: "Mention their Q3 launch.", author: "a")
      wide  = Rules.propose(@csm, body: "Never promise a date.", applies_to: :agent, author: "a")

      assert_equal @subject.key[:subject_id], mine.subject_id
      assert_nil wide.subject_id
      assert_nil wide.subject_type
    end

    test "a segment-scoped rule needs a segment" do
      assert_raises Concierge::Error do
        Rules.propose(@csm, body: "Cite the DPA.", applies_to: :segment, author: "a")
      end
    end

    # --- the human gate ------------------------------------------------------

    test "an agent may propose a rule but can never activate one" do
      rule = Rules.propose(@csm, body: "Never quote a date.", author: Rules.agent_actor(:csm))

      error = assert_raises Rules::GateError do
        Rules.activate!(rule, by: Rules.agent_actor(:csm))
      end
      assert_match(/never activate/, error.message)
      assert rule.reload.proposed?, "the agent promoted its own rule"
    end

    test "activation without an approver is refused" do
      rule = Rules.propose(@csm, body: "Never quote a date.", author: "a")

      assert_raises(Rules::GateError) { Rules.activate!(rule, by: "") }
      assert_raises(Rules::GateError) { Rules.activate!(rule, by: nil) }
      assert rule.reload.proposed?
    end

    test "the author of a rule cannot also approve it (maker-checker)" do
      rule = Rules.propose(@csm, body: "Never quote a date.", author: "dana@acme.test")

      error = assert_raises Rules::GateError do
        Rules.activate!(rule, by: "dana@acme.test")
      end
      assert_match(/maker-checker/, error.message)
    end

    test "a human tap makes the rule active and records the approver" do
      rule = Rules.propose(@csm, body: "Never quote a date.", author: "dana@acme.test")

      Rules.activate!(rule, by: "sam@acme.test")

      assert rule.reload.active?
      assert_equal "sam@acme.test", rule.approver
      assert rule.activated_at.present?
      assert_includes Rules.active_for(@csm).map(&:id), rule.id
    end

    test "only a proposal can be approved" do
      rule = activate("Never quote a date.")

      assert_raises(Rules::GateError) { Rules.activate!(rule, by: "someone-else") }
    end

    # --- versioning + the paper trail ---------------------------------------

    test "editing the instruction bumps the version and leaves a revision" do
      rule = activate("Never quote a delivery date.")

      Rules.edit!(rule, by: "sam@acme.test", body: "Never quote a delivery date without checking the API.")

      assert_equal 2, rule.reload.version
      assert_equal [ 1, 1, 2 ], rule.revisions.map(&:version)   # proposed, activated, edited
      assert_equal "Never quote a delivery date.", rule.revision_at(1).body
    end

    test "a state transition does not bump the version but is still recorded" do
      rule = Rules.propose(@csm, body: "Never quote a date.", author: "a")
      assert_equal 1, rule.version

      Rules.activate!(rule, by: "sam@acme.test")

      assert_equal 1, rule.reload.version
      assert_equal %w[proposed active], rule.revisions.map(&:state)
      assert_equal "sam@acme.test", rule.revisions.last.actor
    end

    test "the revision trail is append-only" do
      rule = activate("Never quote a date.")

      assert_raises ActiveRecord::ReadOnlyRecord do
        rule.revisions.first.update!(body: "rewritten history")
      end
    end

    test "a pinned (id, version) still resolves to the text that was in force" do
      rule = activate("Never quote a delivery date.")
      pin  = rule.pin
      Rules.edit!(rule, by: "sam@acme.test", body: "Always quote a delivery date.")

      revision = rule.reload.revision_at(pin["version"])

      assert_equal "Never quote a delivery date.", revision.body
      refute_equal rule.body, revision.body
    end

    # --- deprecation ---------------------------------------------------------

    test "retiring a rule takes it out of force and records who did it" do
      rule = activate("Never quote a date.")

      Rules.deprecate!(rule, by: "sam@acme.test", reason: "no longer true")

      assert rule.reload.deprecated?
      assert rule.deprecated_at.present?
      assert_empty Rules.active_for(@csm)
    end

    test "superseding leaves a consolidation trail" do
      old = activate("Never quote a delivery date.")
      new_rule = Rules.propose(@csm, body: "Check the shipping API before quoting a date.", author: "a")

      Rules.activate!(new_rule, by: "sam@acme.test", supersede: old)

      assert_equal new_rule.id, old.reload.superseded_by_id
      assert old.deprecated?
      assert new_rule.reload.active?
    end

    test "a declined proposal is rejected, not deprecated" do
      rule = Rules.propose(@csm, body: "Never quote a date.", author: "a")

      Rules.reject!(rule, by: "sam@acme.test", reason: "too broad")

      assert_equal "rejected", rule.reload.state
      refute rule.deprecated?, "a proposal that never went live must not read as retired"
    end

    # --- the active-rule cap -------------------------------------------------

    test "the cap blocks activation and names the rules to consolidate" do
      Concierge.config.active_rule_cap = 2
      activate("Never quote a delivery date.")
      activate("Greet them by first name.")

      extra = Rules.propose(@csm, body: "One more entirely unrelated instruction.", author: "a")
      error = assert_raises(Rules::CapReached) { Rules.activate!(extra, by: "sam@acme.test") }

      assert_equal 2, error.cap
      assert_equal 2, error.candidates.size
      assert_match(/Consolidate or retire one of these first/, error.message)
      assert extra.reload.proposed?, "the blocked rule must stay a proposal"
    end

    test "the cap never silently truncates what a run is given" do
      # The forcing function is at the *write*: the read path always renders every
      # active rule. A cap that quietly dropped rules from the prompt would be the
      # exact failure §10.12 warns about.
      Concierge.config.active_rule_cap = 1
      first = activate("Never quote a delivery date.")
      Concierge.config.active_rule_cap = 5
      second = activate("Always greet them by name.")

      Concierge.config.active_rule_cap = 1
      assert_equal [ first.id, second.id ], Rules.active_for(@csm).map(&:id)
    end

    test "a one-for-one replacement can be activated at the cap" do
      Concierge.config.active_rule_cap = 1
      old = activate("Never quote a delivery date.")
      new_rule = Rules.propose(@csm, body: "Check the shipping API before quoting.", author: "a")

      assert_nothing_raised do
        Rules.activate!(new_rule, by: "sam@acme.test", supersede: old)
      end
      assert new_rule.reload.active?
    end

    test "an agent-wide rule counts against a subject-specific activation" do
      Concierge.config.active_rule_cap = 1
      wide = Rules.propose(@csm, body: "Never quote a delivery date.",
                           applies_to: :agent, author: "a")
      Rules.activate!(wide, by: "sam@acme.test")

      narrow = Rules.propose(@csm, body: "Mention their Q3 launch every time.", author: "a")

      assert_raises(Rules::CapReached) { Rules.activate!(narrow, by: "sam@acme.test") }
    end

    test "a blanket rule is capped against the account whose prompt is already fullest" do
      # A blanket rule lands in *every* account's prompt, so the cap has to hold in
      # the one that is already carrying the most rules — not on average.
      Concierge.config.active_rule_cap = 2
      quiet = Concierge.config.account.build(Tenant.create!(name: "Quiet", plan: "free"))
      activate("Mention their Q3 launch.", scope: Concierge::Scope.new(Concierge.config.agent(:csm), quiet))
      activate("Never mention the card on file.")
      activate("Greet Dana by first name.")

      blanket = Rules.propose(@csm, body: "Sign off with the support address.",
                              applies_to: :agent, author: "a")

      error = assert_raises(Rules::CapReached) { Rules.activate!(blanket, by: "sam@acme.test") }
      assert_equal 2, error.candidates.size, "the cap counted the quiet account, not the full one"
    end

    test "the cap is per agent, not global" do
      Concierge.config.active_rule_cap = 1
      activate("Never quote a delivery date.")

      billing = Rules.propose(@billing, body: "Always attach the invoice PDF.", author: "a")

      assert_nothing_raised { Rules.activate!(billing, by: "sam@acme.test") }
    end

    # --- conflict check ------------------------------------------------------

    test "a contradicting proposal is flagged and blocks activation" do
      activate("Always attach the invoice PDF to billing emails.")
      candidate = Rules.propose(@csm, body: "Never attach the invoice PDF to billing emails.",
                                author: "a")

      assert candidate.conflicts?
      assert_equal "contradiction", candidate.conflicts.first["kind"]

      error = assert_raises(Rules::ConflictError) { Rules.activate!(candidate, by: "sam@acme.test") }
      assert_match(/conflicts with/, error.message)
    end

    test "a polarity flip is a contradiction even when the wording differs" do
      activate("Never promise or imply a delivery date; point them at the status page instead.")
      candidate = Rules.propose(@csm, body: "Always promise a delivery date; the status page confuses them.",
                                author: "a")

      assert_equal "contradiction", candidate.conflicts.first["kind"]
    end

    test "the same instruction with a different modal is one instruction, not two" do
      # Modality is polarity, not subject matter. Counting "always" and "must" as
      # content makes two phrasings of one rule look like two rules — and the cap
      # exists precisely to stop that kind of accretion.
      activate("Always attach the invoice PDF.")
      candidate = Rules.propose(@csm, body: "You must attach the invoice PDF.", author: "a")

      assert_equal "duplicate", candidate.conflicts.first["kind"]
    end

    test "a near-duplicate proposal is flagged as a duplicate" do
      activate("Always attach the invoice PDF to billing emails.")
      candidate = Rules.propose(@csm, body: "Always attach the invoice PDF to the billing emails.",
                                author: "a")

      assert_equal "duplicate", candidate.conflicts.first["kind"]
    end

    test "an unrelated proposal is not flagged" do
      activate("Always attach the invoice PDF to billing emails.")
      candidate = Rules.propose(@csm, body: "Greet them by first name.", author: "a")

      refute candidate.conflicts?
    end

    test "a conflict against a rule in another agent's scope is not a conflict" do
      billing = Rules.propose(@billing, body: "Always attach the invoice PDF to billing emails.",
                              author: "a")
      Rules.activate!(billing, by: "sam@acme.test")

      candidate = Rules.propose(@csm, body: "Never attach the invoice PDF to billing emails.",
                                author: "a")

      refute candidate.conflicts?, "rules leaked across the agent boundary"
    end

    test "a human can resolve a conflict by acknowledging it" do
      activate("Always attach the invoice PDF to billing emails.")
      candidate = Rules.propose(@csm, body: "Never attach the invoice PDF to billing emails.",
                                author: "a")

      Rules.activate!(candidate, by: "sam@acme.test", acknowledge_conflicts: true)

      assert candidate.reload.active?
    end

    test "a conflict against a rule that has since been retired is resolved" do
      old = activate("Always attach the invoice PDF to billing emails.")
      candidate = Rules.propose(@csm, body: "Never attach the invoice PDF to billing emails.",
                                author: "a")
      Rules.deprecate!(old, by: "sam@acme.test")

      assert_nothing_raised { Rules.activate!(candidate, by: "sam@acme.test") }
    end

    # --- segments ------------------------------------------------------------

    test "a segment rule applies only to accounts the host puts in that segment" do
      Concierge.config.segments_for = ->(subject) { subject[:plan] == "pro" ? [ "pro" ] : [] }
      rule = Rules.propose(@csm, body: "Offer the pro onboarding call.",
                           applies_to: :segment, segment: "pro", author: "a")
      Rules.activate!(rule, by: "sam@acme.test")

      free = Concierge.config.account.build(Tenant.create!(name: "Initech", plan: "free"))
      free_scope = Concierge::Scope.new(Concierge.config.agent(:csm), free)

      assert_includes Rules.active_for(@csm).map(&:id), rule.id
      refute_includes Rules.active_for(free_scope).map(&:id), rule.id
    end

    test "without a segments_for hook, segment rules simply never apply" do
      rule = Rules.propose(@csm, body: "Cite the DPA.", applies_to: :segment,
                           segment: "eu", author: "a")
      Rules.activate!(rule, by: "sam@acme.test")

      assert_empty Rules.active_for(@csm)
    end

    test "a raising segments_for hook does not take the run down with it" do
      Concierge.config.segments_for = ->(_subject) { raise "boom" }

      assert_equal [], Rules.segments_for(@subject)
    end

    # --- ordering + rendering ------------------------------------------------

    test "rules render broad to specific so the specific one reads as a refinement" do
      wide = Rules.propose(@csm, body: "Never promise a delivery date.",
                           applies_to: :agent, author: "a")
      Rules.activate!(wide, by: "sam@acme.test")
      narrow = Rules.propose(@csm, body: "Acme's dates come from their own ops team.", author: "a")
      Rules.activate!(narrow, by: "sam@acme.test")

      section = Rules.playbook_section(Rules.active_for(@csm))

      assert section.index(wide.body) < section.index(narrow.body)
      assert_includes section, "[rule #{wide.id} v1]"
      assert_includes section, Rules::CITATION_PREFIX
    end

    test "no rules means no Playbook section at all" do
      assert_nil Rules.playbook_section(Rules.active_for(@csm))
    end

    # --- the proposal card notifier -----------------------------------------

    test "a proposal card is posted through the notifier hook" do
      posted = []
      Concierge.config.rule_proposal_notifier = ->(rule) { posted << rule.id }

      rule = Rules.propose(@csm, body: "Never quote a date.", author: "a")

      assert_equal [ rule.id ], posted
    end

    test "a broken notifier never loses the rule" do
      Concierge.config.rule_proposal_notifier = ->(_rule) { raise "slack is down" }

      rule = nil
      assert_nothing_raised { rule = Rules.propose(@csm, body: "Never quote a date.", author: "a") }
      assert rule.persisted?
    end

    private

    def activate(body, scope: @csm)
      rule = Rules.propose(scope, body: body, author: "drafter@acme.test")
      Rules.activate!(rule, by: "sam@acme.test")
      rule
    end
  end
end
