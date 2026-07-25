# Sample data for exercising the engine by hand: three accounts at different
# points in their lifecycle, each with memory, routines, and a delivery history.
#
#   bin/rails db:seed && bin/rails server
#   open http://localhost:3000/concierge/admin/memories

require "securerandom"

[ Concierge::Memory, Concierge::Routine, Concierge::ChannelDelivery,
  Concierge::Handoff, Concierge::OutreachPreference, Concierge::Conversation,
  Concierge::OutboxItem, Concierge::BudgetLedger, Concierge::AgentRuleRevision,
  Concierge::AgentRule, Concierge::AgentRun, User, Tenant ].each(&:delete_all)

acme = Tenant.create!(name: "Acme Corp", plan: "pro", last_active_at: 2.days.ago)
acme.users.create!(email: "dana@acme.test")

globex = Tenant.create!(name: "Globex", plan: "enterprise", last_active_at: 6.hours.ago)
globex.users.create!(email: "hank@globex.test")
globex.users.create!(email: "lena@globex.test")

initech = Tenant.create!(name: "Initech", plan: "free", last_active_at: 41.days.ago)
initech.users.create!(email: "peter@initech.test")

def subject_for(tenant) = Concierge.config.account.find_subject(tenant.id)

# Everything below is keyed by an (Agent × Subject) Scope, not by the account
# alone: this host declares two business functions (:csm and :billing) over the
# same Tenants, and their memory, routines and deliveries are separate.
def scope_for(slug, tenant)
  Concierge::Scope.new(Concierge.config.agent(slug), subject_for(tenant))
end

# --- Memory: a mix of agent-learned and human-authored, one pinned ------------

[
  [ :csm,     acme,    "agent", "goal",       "Wants to publish a changelog before their Q3 launch.", false ],
  [ :csm,     acme,    "agent", "preference", "Prefers short emails; asked for no more than one a week.", false ],
  [ :csm,     acme,    "human", "account",    "Dana is the champion here. CEO is skeptical of AI tooling — keep it low-key.", true ],
  [ :billing, acme,    "agent", "billing",    "Card on file expires in March; no backup payment method.", false ],
  [ :billing, acme,    "human", "billing",    "Invoice #4471 was disputed in May and resolved in their favour.", true ],
  [ :csm,     globex,  "agent", "goal",       "Rolling out to 4 more teams next quarter.", false ],
  [ :csm,     globex,  "human", "account",    "Renewal is in November. Procurement wants SOC 2 docs.", true ],
  [ :csm,     globex,  "agent", "blocker",    "Hit a rate limit on the API twice last week.", false ],
  [ :billing, globex,  "agent", "billing",    "Procurement pays by wire, net-30. Never auto-charge this account.", false ],
  [ :csm,     initech, "agent", "blocker",    "Signed up 6 weeks ago, never completed onboarding.", false ]
].each do |slug, tenant, source, category, body, pinned|
  Concierge::ContextStore.new.remember(
    scope_for(slug, tenant),
    body: body, category: category, source: source, pinned: pinned
  )
end

# Facts about the relationship that every agent legitimately shares. Written with
# an explicit opt-in; read automatically by both agents (design §10.3).
Concierge::ContextStore.new.remember(
  scope_for(:csm, acme), shared: true, source: "human",
  body: "Acme is an EU entity — GDPR data-processing addendum applies."
)

# --- Routines: one agent-authored, one customer-requested, one paused ---------

Concierge::Routine.create!(
  **scope_for(:csm, acme).key,
  schedule: "0 9 * * 1", author: "agent", channel: "email",
  instruction: "Weekly review: check activation progress and reach out if something is worth their attention."
)

Concierge::Routine.create!(
  **scope_for(:csm, globex).key,
  schedule: "0 8 * * 5", author: "customer", channel: "email",
  instruction: "Send Hank a Friday summary of changelog views across all teams."
)

Concierge::Routine.create!(
  **scope_for(:billing, globex).key,
  schedule: "0 7 1 * *", author: "agent", channel: "email",
  instruction: "Invoice day: confirm the wire arrived and flag anything unpaid past net-30."
)

Concierge::Routine.create!(
  **scope_for(:csm, initech).key,
  schedule: "0 9 * * 1", author: "agent", channel: "email", enabled: false,
  instruction: "Weekly nudge — paused after the account went quiet."
)

# --- Delivery audit trail ----------------------------------------------------

[
  [ :csm,     acme,    "email",  "outreach", 3.days.ago ],
  [ :csm,     acme,    "in_app", "reply",    2.days.ago ],
  [ :billing, acme,    "email",  "outreach", 5.days.ago ],
  [ :csm,     globex,  "email",  "outreach", 8.days.ago ],
  [ :csm,     globex,  "email",  "routine",  1.day.ago ],
  [ :csm,     initech, "email",  "outreach", 30.days.ago ]
].each do |slug, tenant, channel, kind, sent_at|
  Concierge::ChannelDelivery.create!(
    **scope_for(slug, tenant).key,
    channel: channel, kind: kind, sent_at: sent_at,
    unsubscribe_token: SecureRandom.hex(16)
  )
end

# --- Governance state: Acme asked for less email; Initech opted out -----------

Concierge::OutreachPreference.create!(**subject_for(acme).key, frequency: "less")
Concierge::OutreachPreference.create!(**subject_for(initech).key, opted_out: true)

# --- A human takeover of the CSM's thread with Globex -------------------------
# Per (agent, account): billing carries on talking to Globex regardless.

Concierge::Handoff.seize!(scope_for(:csm, globex), operator: "bruno@acme.test")

# --- One drafted proposal, from the agent whose authority envelope gates -------
# :billing declares `default :human_approval`, so its outreach stages for a human
# instead of sending. The CSM stays autonomous-within-caps.

Concierge::OutboxItem.create!(
  **scope_for(:billing, acme).key,
  body: "Heads up: the card on file expires before the next invoice date. " \
        "Want me to send Dana a link to update it?",
  channel: "email", kind: "outreach", state: "pending"
)

# --- Rules: the human-gated behavioral layer (design §10.2) -------------------
# Memory is what the agent knows about a relationship. A *rule* is a generalized,
# versioned instruction about how it behaves — and it only goes into force when a
# human taps Approve. Nothing below activates itself.

# Three in force, one of them account-specific, one a code-enforced guard.
in_force = [
  [ :csm,     nil,  :agent,
    "Never promise or imply a delivery date; point them at the status page instead.",
    "advisory", nil ],
  [ :csm,     acme, :subject,
    "Acme's CEO is skeptical of AI tooling — keep the tone low-key and never mention automation.",
    "advisory", nil ],
  [ :billing, nil,  :agent,
    "Never put the word \"guarantee\" in a billing email.",
    "guard",
    { "action_class" => "message.outreach", "deny_when" => { "body" => { "matches" => "guarantee" } } } ]
].map do |slug, tenant, applies_to, body, enforcement, predicate|
  scope = scope_for(slug, tenant || acme)
  rule  = Concierge::Rules.propose(
    scope, body: body, applies_to: applies_to, enforcement: enforcement,
    predicate: predicate, author: "dana@acme.test",
    provenance: { "source" => "authored" }
  )
  Concierge::Rules.activate!(rule, by: "operator@acme.test")
  # These have been in force for a month, so the weekly dreaming job has a real
  # sample to reason about rather than three rules approved a second ago.
  rule.update_column(:activated_at, 30.days.ago)
  rule
end

# A segment rule: applies to enterprise accounts only (see `segments_for` in the
# initializer), so Globex sees it and Acme does not.
enterprise_rule = Concierge::Rules.propose(
  scope_for(:csm, globex),
  body: "For enterprise accounts, cite the SOC 2 report by name when asked about security.",
  applies_to: :segment, segment: "enterprise", author: "dana@acme.test",
  provenance: { "source" => "authored" }
)
Concierge::Rules.activate!(enterprise_rule, by: "operator@acme.test")

# A proposal card awaiting a human tap, drafted from a verbatim human correction —
# the write path §10.2 specifies, minus the job (which the app runs for real).
Concierge::Rules.propose(
  scope_for(:billing, acme),
  body:   "Always attach the invoice PDF to a billing email.",
  author: Concierge::Rules.agent_actor(:billing),
  provenance: {
    "source"       => "human_correction",
    "verbatim"     => "You sent Dana an invoice email with no PDF attached again. " \
                      "Always attach the invoice PDF.",
    "corrected_by" => "bruno@acme.test"
  }
)

# ...and one that *contradicts* a rule already in force, so the conflict check has
# something to surface. It cannot be approved until a human resolves it.
Concierge::Rules.propose(
  scope_for(:csm, acme),
  body:   "Always promise a delivery date; the status page confuses them.",
  author: Concierge::Rules.agent_actor(:csm),
  provenance: { "source" => "human_correction",
                "verbatim" => "Always promise a delivery date. The status page confuses " \
                              "them and being vague loses deals.",
                "corrected_by" => "hank@globex.test" }
)

# --- Run provenance: what each turn was actually told (design §10.4) -----------
# Enough history for the dreaming job to have something to reason about: the
# account-specific rule gets cited, the blanket one never does.

blanket, account_specific = in_force

6.times do |i|
  Concierge::AgentRun.create!(
    **scope_for(:csm, acme).key,
    trigger: i.even? ? "proactive" : "reactive", status: "ok",
    model: "claude-sonnet-4-5", input_tokens: 900 + (i * 40), output_tokens: 120 + i,
    snapshot_digest: Concierge::Snapshot.for(
      subject_for(acme), playbook: Concierge.config.agent(:csm).playbook
    ).digest,
    memory_ids: Concierge::Memory.for_scope(scope_for(:csm, acme)).limit(2).pluck(:id),
    rules: [ blanket.pin, account_specific.pin ],
    rule_ids_applied: [ account_specific.id ],
    created_at: (10 - i).days.ago
  )
end

# One run where the model cited a rule that was never in its prompt — a claim the
# provenance screen flags rather than discards.
Concierge::AgentRun.create!(
  **scope_for(:billing, globex).key,
  trigger: "proactive", status: "ok", model: "claude-sonnet-4-5",
  input_tokens: 640, output_tokens: 88,
  rules: [], rule_ids_applied: [ 9999 ], unknown_rule_ids: [ 9999 ],
  created_at: 1.day.ago
)

puts "Seeded #{Tenant.count} accounts across #{Concierge.config.agents.map(&:slug).join(' + ')} agents: " \
     "#{Concierge::Memory.count} memories, #{Concierge::Routine.count} routines, " \
     "#{Concierge::ChannelDelivery.count} deliveries, #{Concierge::OutboxItem.count} drafted."
puts "Memory namespaces: #{Concierge::Memory.group(:agent_slug).count.sort.map { |k, v| "#{k}=#{v}" }.join(', ')}."
puts "Rules: #{Concierge::AgentRule.active.count} active, " \
     "#{Concierge::AgentRule.proposed.count} awaiting a human tap " \
     "(cap #{Concierge::Rules.cap} per scope). #{Concierge::AgentRun.count} runs recorded."
puts "Unsubscribe link to try: /concierge/unsubscribe/#{Concierge::ChannelDelivery.last.unsubscribe_token}"
