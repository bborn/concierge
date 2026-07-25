# Sample data for exercising the engine by hand: three accounts at different
# points in their lifecycle, each with memory, routines, and a delivery history.
#
#   bin/rails db:seed && bin/rails server
#   open http://localhost:3000/concierge/admin/memories

require "securerandom"

[ Concierge::Memory, Concierge::Routine, Concierge::ChannelDelivery,
  Concierge::Handoff, Concierge::OutreachPreference, User, Tenant ].each(&:delete_all)

acme = Tenant.create!(name: "Acme Corp", plan: "pro", last_active_at: 2.days.ago)
acme.users.create!(email: "dana@acme.test")

globex = Tenant.create!(name: "Globex", plan: "enterprise", last_active_at: 6.hours.ago)
globex.users.create!(email: "hank@globex.test")
globex.users.create!(email: "lena@globex.test")

initech = Tenant.create!(name: "Initech", plan: "free", last_active_at: 41.days.ago)
initech.users.create!(email: "peter@initech.test")

def subject_for(tenant) = Concierge.config.account.find_subject(tenant.id)

# --- Memory: a mix of agent-learned and human-authored, one pinned ------------

[
  [ acme,    "agent", "goal",       "Wants to publish a changelog before their Q3 launch.", false ],
  [ acme,    "agent", "preference", "Prefers short emails; asked for no more than one a week.", false ],
  [ acme,    "human", "account",    "Dana is the champion here. CEO is skeptical of AI tooling — keep it low-key.", true ],
  [ globex,  "agent", "goal",       "Rolling out to 4 more teams next quarter.", false ],
  [ globex,  "human", "account",    "Renewal is in November. Procurement wants SOC 2 docs.", true ],
  [ globex,  "agent", "blocker",    "Hit a rate limit on the API twice last week.", false ],
  [ initech, "agent", "blocker",    "Signed up 6 weeks ago, never completed onboarding.", false ]
].each do |tenant, source, category, body, pinned|
  Concierge::Memory.create!(
    **subject_for(tenant).key,
    body: body, category: category, source: source, pinned: pinned, tier: "account"
  )
end

# --- Routines: one agent-authored, one customer-requested, one paused ---------

Concierge::Routine.create!(
  **subject_for(acme).key,
  schedule: "0 9 * * 1", author: "agent", channel: "email",
  instruction: "Weekly review: check activation progress and reach out if something is worth their attention."
)

Concierge::Routine.create!(
  **subject_for(globex).key,
  schedule: "0 8 * * 5", author: "customer", channel: "email",
  instruction: "Send Hank a Friday summary of changelog views across all teams."
)

Concierge::Routine.create!(
  **subject_for(initech).key,
  schedule: "0 9 * * 1", author: "agent", channel: "email", enabled: false,
  instruction: "Weekly nudge — paused after the account went quiet."
)

# --- Delivery audit trail ----------------------------------------------------

[
  [ acme,   "email", "outreach",  3.days.ago ],
  [ acme,   "in_app", "reply",    2.days.ago ],
  [ globex, "email", "outreach",  8.days.ago ],
  [ globex, "email", "routine",   1.day.ago ],
  [ initech, "email", "outreach", 30.days.ago ]
].each do |tenant, channel, kind, sent_at|
  Concierge::ChannelDelivery.create!(
    **subject_for(tenant).key,
    channel: channel, kind: kind, sent_at: sent_at,
    unsubscribe_token: SecureRandom.hex(16)
  )
end

# --- Governance state: Acme asked for less email; Initech opted out -----------

Concierge::OutreachPreference.create!(**subject_for(acme).key, frequency: "less")
Concierge::OutreachPreference.create!(**subject_for(initech).key, opted_out: true)

# --- An active human takeover on Globex --------------------------------------

Concierge::Handoff.seize!(subject_for(globex), operator: "bruno@acme.test")

# --- Phase 10 step-0 spike: namespaced memory for two agents over one account --
# Throwaway. The spike has no agent_slug column, so the namespace is folded into
# subject_type ("csm/account"). Visible at /concierge/admin/spike.

if Concierge.config.multi_agent_spike
  def spike_scope(slug, tenant) = Concierge::Spike.scope_for(slug, subject_for(tenant))

  store = Concierge::Spike::MemoryStore.new

  store.remember(spike_scope(:csm, acme), source: :human, pinned: true,
    body: "Dana is the champion here. CEO is skeptical of AI tooling — keep it low-key.")
  store.remember(spike_scope(:csm, acme), category: "goal",
    body: "Wants to publish a changelog before their Q3 launch.")
  store.remember(spike_scope(:billing, acme), category: "billing",
    body: "Card on file expires in March; no backup payment method.")
  store.remember(spike_scope(:billing, acme), category: "billing",
    body: "Invoice #4471 was disputed in May and resolved in their favour.")
  store.remember(spike_scope(:csm, acme), shared: true, source: :human,
    body: "Acme is an EU entity — GDPR data-processing addendum applies.")

  store.remember(spike_scope(:billing, globex), category: "billing",
    body: "Procurement pays by wire, net-30. Never auto-charge this account.")
  store.remember(spike_scope(:csm, globex), category: "goal",
    body: "Rolling out to 4 more teams next quarter.")

  puts "Spike: #{Concierge.config.agents.map(&:slug).join(' + ')} agents, " \
       "namespaces #{Concierge::Memory.where("subject_type LIKE '%/%'").distinct.pluck(:subject_type).sort.join(', ')}."
end

puts "Seeded #{Tenant.count} accounts, #{Concierge::Memory.count} memories, " \
     "#{Concierge::Routine.count} routines, #{Concierge::ChannelDelivery.count} deliveries."
puts "Unsubscribe link to try: /concierge/unsubscribe/#{Concierge::ChannelDelivery.last.unsubscribe_token}"
