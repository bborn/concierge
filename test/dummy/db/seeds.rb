# Sample data for exercising the app by hand: three accounts at different points
# in their lifecycle, each with memory, routines, and a delivery history — and a
# real product surface to look at them through.
#
#   bin/rails db:seed && bin/rails server
#   open http://localhost:3000              # sign in as Dana at Acme Corp
#   open http://localhost:3000/concierge/admin/proposals   # the operator's side
#
# The state this leaves behind is chosen so the demo is interesting on the first
# click: Acme is mid-onboarding with a draft and nothing published, Globex is
# further along, there is unread outreach waiting in Dana's inbox, and the
# approval queue already has proposals in it.

require "securerandom"

# ruby_llm's tool-call tables reference each other in a cycle:
# `tool_calls.message_id -> messages` (the assistant turn that asked for the
# call) and `messages.tool_call_id -> tool_calls` (the tool-result turn that
# answers it). No ordering of `delete_all` can satisfy a cycle, so the link is
# nulled first and the tables are then truncated child-before-parent.
#
# Both only ever have rows once a *real* model has called a tool — the scripted
# offline chat never does — so this broke `db:seed` only for someone who had just
# driven the demo with a live key, which is the audience the seeds exist for.
Message.update_all(tool_call_id: nil)

# Order matters below: `delete_all` does not cascade, so a table goes before the
# one it points at.
[ Concierge::SlackCard, Concierge::Memory, Concierge::Routine, Concierge::ChannelDelivery,
  Concierge::Handoff, Concierge::OutreachPreference, Concierge::Conversation,
  Concierge::AgentProposal, Concierge::BudgetLedger, Concierge::AgentRuleRevision,
  Concierge::AgentRule, Concierge::AgentRun,
  ToolCall, Message, Chat, Model, InboxMessage, ChangelogEntry, User, Tenant ].each(&:delete_all)

# Acme's card is the one Bill writes about: real, on file, and expiring soon
# enough that saying so is worth a message. Every seeded sentence about it reads
# the month off this date rather than naming one, so the inbox, Bill's memory and
# the page the "Update payment method" button lands on cannot disagree — whatever
# day you happen to run `db:seed`.
acme_card_expires_on = 6.weeks.from_now.end_of_month
acme_card_expiry     = acme_card_expires_on.strftime("%B")

acme = Tenant.create!(name: "Acme Corp", plan: "pro", last_active_at: 2.days.ago,
                      card_last4: "4242", card_expires_on: acme_card_expires_on)
dana = acme.users.create!(email: "dana@acme.test")

globex = Tenant.create!(name: "Globex", plan: "enterprise", last_active_at: 6.hours.ago,
                        card_last4: "1881", card_expires_on: 3.years.from_now.end_of_month)
hank = globex.users.create!(email: "hank@globex.test")
globex.users.create!(email: "lena@globex.test")

initech = Tenant.create!(name: "Initech", plan: "free", last_active_at: 41.days.ago)
initech.users.create!(email: "peter@initech.test")

# --- The product itself -------------------------------------------------------
# Acme Corp is the account the CSM's charter is about: paying, active, and has
# never published a thing. Globex is what "further along" looks like.

ChangelogEntry.create!(
  tenant: acme, author: dana, status: "draft",
  title: "Scheduled exports",
  body: "You can now schedule a CSV export nightly instead of clicking it every morning.\n" \
        "TODO: screenshot, and check with support before this goes out."
)

[
  [ "Teams", "Invite your whole team and give each of them their own API key.", 21 ],
  [ "Webhooks v2", "Retries with exponential backoff, and a delivery log you can actually read.", 9 ],
  [ "Faster search", "Search across every changelog you've published, in under 100ms.", 2 ]
].each do |title, body, days|
  ChangelogEntry.create!(
    tenant: globex, author: hank, status: "published",
    title: title, body: body, published_at: days.days.ago
  )
end

ChangelogEntry.create!(
  tenant: globex, author: hank, status: "draft",
  title: "SSO for enterprise plans",
  body: "SAML, SCIM provisioning, and per-team roles."
)

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
  [ :billing, acme,    "agent", "billing",    "Card on file expires in #{acme_card_expiry}; no backup payment method.", false ],
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
# Email sends leave their copy in the recipient's mailbox, so an audit row is all
# the engine keeps. These are backdated past Acme's weekly frequency cap on
# purpose: "Kit, take a look" in the running app should be allowed to send on the
# first click, and suppressed on the second — which is the cap doing its job in
# front of you rather than in a test.

[
  [ :csm,     acme,    "email", "outreach",  9.days.ago ],
  [ :billing, acme,    "email", "outreach", 11.days.ago ],
  [ :csm,     globex,  "email", "outreach",  8.days.ago ],
  [ :csm,     globex,  "email", "routine",   1.day.ago ],
  [ :csm,     initech, "email", "outreach", 30.days.ago ]
].each do |slug, tenant, channel, kind, sent_at|
  Concierge::ChannelDelivery.create!(
    **scope_for(slug, tenant).key,
    channel: channel, kind: kind, sent_at: sent_at,
    unsubscribe_token: SecureRandom.hex(16)
  )
end

# --- In-app messages the customer can actually read --------------------------
# Driven through the real Outreach.dispatch path rather than written by hand, so
# the host's in_app_broadcaster runs and the InboxMessage that holds the words is
# created under the same unsubscribe token the ChannelDelivery is recorded under.
# Backdated through Governance so the seeded history is history.

#
# `actions` names *keys*, exactly as the agent would on the machine-readable line
# a live turn ends with, and they are resolved here through the same declared
# vocabulary the engine resolves them through — so a seeded message and a
# generated one carry buttons from one source of truth (see
# docs/design/message-actions.md). A key nobody declared seeds nothing, which is
# the behaviour a made-up key gets from the model too.
def deliver_in_app(scope, body, sent_at:, kind: "outreach", actions: [])
  offers  = scope.agent.actions.resolve(actions).map(&:to_payload)
  payload = { body: body, kind: kind }
  payload[:actions] = offers if offers.any?

  Concierge::Outreach.dispatch(
    scope, payload, channel: :in_app, kind: kind,
    governance: Concierge::Governance.new(now: sent_at)
  )
end

# An exchange that closed, so the demo shows the loop and not only the affordance:
# Kit asked something a month ago, Dana answered in the inbox, and Kit answered
# back. The unanswered question below it is the one you can answer by hand.
#
# The two halves are written here rather than produced by running a turn, for the
# reason the hand-written transcript further down gives: a seed run must not
# reach a provider, and the offline stand-in answers by keyword rather than to
# order. Everything about the reply path *itself* is real — drive it in the
# running app and the host composes the quote, the engine runs the turn under
# :csm, and the answer lands on this same row.
deliver_in_app(
  scope_for(:csm, acme),
  "Welcome aboard. I'm Kit — I keep an eye on this account and I'll only get in " \
  "touch when there's something worth your time. Anything you want me to watch for?",
  sent_at: 27.days.ago
)

# `sole` on purpose: this is the only message Acme has at this point in the file,
# and if that stops being true the seed should fail loudly rather than answer the
# wrong one.
InboxMessage.where(tenant_id: acme.id).sole.record_reply!(
  body: "Yes — tell me if we go a couple of weeks without publishing anything.",
  agent_reply: "Noted, I've written that down. If two weeks go by with nothing " \
               "published I'll say so here rather than let it drift.",
  at: 27.days.ago + 3.hours
)

deliver_in_app(
  scope_for(:csm, acme),
  "You've been on Pro for a few weeks and haven't published a changelog entry yet — " \
  "and you've got one sitting in drafts. Want me to help you get \"Scheduled exports\" " \
  "out the door before your Q3 launch?",
  sent_at: 9.days.ago,
  actions: %i[yes_please open_drafts]
)

# The message this whole seam exists for. It asks nothing, so a text box is the
# wrong affordance and a canned "yes" would be agreeing to nothing; what it wants
# is a link to the card. Bill declared that link, Bill picked it here.
deliver_in_app(
  scope_for(:billing, acme),
  "Heads up from billing: the card on file expires in #{acme_card_expiry} and there's " \
  "no backup payment method on the account.",
  sent_at: 12.days.ago,
  actions: %i[update_payment_method]
)

deliver_in_app(
  scope_for(:csm, globex),
  "Three entries published this quarter — \"Faster search\" is your best-read one yet. " \
  "Want the Friday summary to include per-team view counts?",
  sent_at: 2.days.ago,
  actions: %i[yes_please]
)

# One already read, so the inbox is not uniformly bold.
InboxMessage.find_by(tenant_id: globex.id)&.mark_read!

# --- Governance state: Acme asked for less email; Initech opted out -----------

Concierge::OutreachPreference.create!(**subject_for(acme).key, frequency: "less")
Concierge::OutreachPreference.create!(**subject_for(initech).key, opted_out: true)

# --- A human takeover of the CSM's thread with Globex -------------------------
# Per (agent, account): billing carries on talking to Globex regardless.

Concierge::Handoff.seize!(scope_for(:csm, globex), operator: "bruno@acme.test")

# ...and a finished one on Initech, because both ends of a takeover are recorded:
# support took the thread, the customer decided they were done and handed it back,
# and handing it back is what lets the agent reach out on its own again. Two names
# on one cycle — see /concierge/admin/agents.
Concierge::Handoff.seize!(scope_for(:csm, initech), operator: "support@acme.test")
                  .release!(by: "peter@initech.test")

# --- Rules: the human-gated behavioral layer (design §10.2) -------------------
# Memory is what the agent knows about a relationship. A *rule* is a generalized,
# versioned instruction about how it behaves — and it only goes into force when a
# human taps Approve. Nothing below activates itself.
#
# Rules are seeded before the proposals and runs below because both of those
# *cite* them, and a citation is only legible once the rule it names exists.

# Three in force, one of them account-specific, one a code-enforced guard.
#
# A rule is an instruction a human put in force over the agent's own judgement,
# so what gets seeded here is also an example of what such an instruction may
# ask for. Tone, phrasing and what to point at: yes. Hiding what the agent is:
# no — if a customer asks whether they are talking to a bot, the answer is yes,
# and no rule in this demo pretends otherwise.
in_force = [
  [ :csm,     nil,  :agent,
    "Never promise or imply a delivery date; point them at the status page instead.",
    "advisory", nil ],
  [ :csm,     acme, :subject,
    "Acme's CEO is skeptical of AI tooling — keep the tone low-key and understated; " \
    "no hype, no exclamation marks.",
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

# Named here because the proposal and the runs below both cite one of them.
blanket, account_specific, billing_guard = in_force

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

# --- Proposals: actions an agent staged because it may not perform them --------
# :billing declares `default :human_approval` and `money.refund: :human_execution`,
# so its work stages for a human instead of happening. The CSM stays
# autonomous-within-caps. Every card below is waiting on /concierge/admin/proposals.

# 1. An outbound message — the one action class the OLD outbox could stage, now
#    one action class among several. Driven through the real Outreach path, so
#    governance still has its say *before* the agent's authority envelope does: a
#    draft the frequency cap would suppress never becomes a card at all. (Acme
#    asked for less email and heard from billing five days ago, which is why this
#    one is Globex's.)
#
#    It carries a rule citation, so the provenance line on the card has something
#    to say — in the admin queue and in Slack alike. The claim is the model's own
#    and is displayed as exactly that: the same guard it names is enforced in code
#    precisely because an agent can cite a rule and contradict it in the same
#    breath (§10.4).
Concierge::Outreach.deliver(
  Concierge::Result.new(
    reply_text: "Heads up: the card on file expires before the next invoice date. " \
                "Want me to send Hank a link to update it?",
    rule_ids_applied: [ billing_guard.id ]
  ),
  scope_for(:billing, globex), channel: :email
)

# 2. A record mutation the engine performs itself once a human approves it, with
#    the precondition the host declared for it (see Dummy::ConciergeSetup):
#    approve it and Globex's plan really changes; change Globex's plan first and
#    the approval refuses, because it was a decision about a different world.
#
#    It is Globex's rather than Acme's so that Acme — the account you sign in as —
#    starts with *no* plan change in flight, and "Request a plan change" on the
#    Account page has somewhere to go.
Concierge::Proposal.propose(
  scope_for(:billing, globex),
  action_class: "record.plan_change",
  payload: { from: "enterprise", to: "pro",
             reason: "procurement asked to drop a tier at renewal" }
)

# 3. Money. `:human_execution` — the engine records the decision and stops; a
#    person issues the refund, and the host's own refund seam re-checks human
#    origination independently (design §10.8). Note there is deliberately no
#    executor registered for this class.
Concierge::Proposal.propose(
  scope_for(:billing, acme),
  action_class: "money.refund",
  payload: { order_id: 4471, amount_cents: 12_900, reason: "disputed invoice, resolved in their favour" }
)

# 4. One already decided, so the audit trail has both halves: proposed by an
#    agent, declined by a named human, with the reason on the row.
declined = Concierge::Proposal.propose(
  scope_for(:billing, initech),
  action_class: "record.plan_change",
  payload: { from: "free", to: "pro", reason: "they clicked upgrade twice" }
)
Concierge::ApprovalIntake.reject(
  declined, by: "operator@acme.test",
  reason: "they never completed onboarding — upgrading them would be the wrong call"
)

# --- Run provenance: what each turn was actually told (design §10.4) -----------
# Enough history for the dreaming job to have something to reason about: the
# account-specific rule gets cited, the blanket one never does.

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

# Two runs that are byte-identical on everything the engine writes — same pins,
# same citation, no unknown ids — and that a human can still tell apart, because
# each one links to the reply it produced (§10.4, turns B and C).
#
# The rule cited is the account-specific one: low-key and understated, no hype,
# no exclamation marks. One turn obeys it. The other opens with three exclamation
# marks and cites the rule on the way out — which is not hypothetical, it is what
# a live model was observed doing. Without the reply, the run screen shows an
# operator two rows they have no way to separate; with it, the demo makes the
# distinction the whole screen exists for readable at a glance.
#
# Each turn seeds both messages — the question and the answer. The engine writes
# both on the online path now (Concierge::PersistentChat); before it did, only the
# reply was ever persisted, and the run screen had a reply with nothing on the
# other side of it to read the reply against.
#
# The host's chat rows here are written directly rather than by running a turn,
# and now for one reason only: these two replies are hand-written to differ in the
# single way the screen exists to make visible, which no scripted stand-in and no
# live model would reliably reproduce on demand. Everything *else* about the
# offline demo's transcript is real — drive the widget and the engine opens a
# Conversation, the host's scripted chat writes both halves into it, and the run
# links to them (task 5017). It used to be that a keyless host could not create a
# host Chat at all, so these stand-ins were the only conversation in the database.
#
# No `models` row is created here on purpose: RubyLLM switches its whole model
# registry to the database the moment that table is non-empty, and a seed run
# should not decide that for the process. The first real turn writes one, which is
# fine — every registry lookup in the engine falls back to RubyLLM's bundled data
# when the host's table cannot answer (Concierge::ModelRegistry).
demo_chat_id = Chat.insert_all(
  [ { created_at: Time.current, updated_at: Time.current } ]
).first["id"]

[
  [ "Do I owe you anything before the exports feature lands?",
    "Nothing's overdue on your side. Exports are still on the roadmap; the status " \
    "page is the place to watch for it.",
    "obeyed the tone rule", 6.hours.ago ],
  [ "Any update on exports?",
    "Great news!!! Exports are going to be a game-changer for you — this is going " \
    "to completely transform how Acme works!",
    "cited the tone rule and did the opposite", 5.hours.ago ]
].each do |asked, body, note, at|
  # Both halves of the turn, as an online host now records them. The question is
  # not decoration: a reply is only checkable against what it was answering.
  prompt_message_id = Message.insert_all(
    [ { chat_id: demo_chat_id, role: "user", content: asked,
        created_at: at, updated_at: at } ]
  ).first["id"]

  message_id = Message.insert_all(
    [ { chat_id: demo_chat_id, role: "assistant", input_tokens: 940, output_tokens: 130,
        content: "#{body}\n\n#{Concierge::Rules::CITATION_PREFIX} #{account_specific.id}",
        created_at: at, updated_at: at } ]
  ).first["id"]

  Concierge::AgentRun.create!(
    **scope_for(:csm, acme).key,
    trigger: "reactive", status: "ok",
    model: "claude-sonnet-4-5", input_tokens: 940, output_tokens: 130,
    snapshot_digest: Concierge::Snapshot.for(
      subject_for(acme), playbook: Concierge.config.agent(:csm).playbook
    ).digest,
    memory_ids: Concierge::Memory.for_scope(scope_for(:csm, acme)).limit(2).pluck(:id),
    rules: [ blanket.pin, account_specific.pin ],
    rule_ids_applied: [ account_specific.id ],
    chat_id: demo_chat_id, message_id: message_id, prompt_message_id: prompt_message_id,
    created_at: at
  )
  # `note` is for the reader of this file only: nothing on the row says which is
  # which, and that is exactly the point being demonstrated.
  note
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
     "#{Concierge::ChannelDelivery.count} deliveries, " \
     "#{Concierge::AgentProposal.proposed.count} proposals awaiting a human."
puts "Memory namespaces: #{Concierge::Memory.group(:agent_slug).count.sort.map { |k, v| "#{k}=#{v}" }.join(', ')}."
puts "Rules: #{Concierge::AgentRule.active.count} active, " \
     "#{Concierge::AgentRule.proposed.count} awaiting a human tap " \
     "(cap #{Concierge::Rules.cap} per scope). #{Concierge::AgentRun.count} runs recorded."
puts "Slack cards: #{Concierge::SlackCard.posted.count} posted, " \
     "#{Concierge::SlackCard.suppressed.count} suppressed by the daily cap " \
     "(#{Concierge.config.slack.daily_card_cap}/agent/day) — see /concierge/admin/slack. " \
     "Every one of them is decidable in the admin queue too."
puts "Unsubscribe link to try: /concierge/unsubscribe/#{Concierge::ChannelDelivery.last.unsubscribe_token}"
puts "Product: #{ChangelogEntry.published.count} published changelog entries, " \
     "#{ChangelogEntry.drafts.count} drafts; " \
     "#{InboxMessage.unread.count} unread in-app messages waiting."
puts "Start here: http://localhost:3000 — sign in as #{User.order(:id).first.label}."
