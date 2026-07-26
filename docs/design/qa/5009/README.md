# QA — a seeded proposal now cites a rule, so the provenance line is reachable

Task 5009. Filed as follow-up from
[`../rule-citation-is-a-claim/README.md`](../rule-citation-is-a-claim/README.md).

## The defect, reproduced first

`app/views/concierge/admin/proposals/index.html.erb` renders a **Rules claimed**
line when `proposal.rule_ids_applied.any?`, and `Concierge::Slack::Card` renders
the equivalent context line. Neither could ever appear in the stock demo. On
`main`, before any change:

```
$ cd test/dummy && bin/rails db:seed
$ bin/rails runner 'Concierge::AgentProposal.order(:id).each { |p|
    puts "##{p.id} #{p.agent_slug} #{p.action_class} rules=#{p.rule_ids_applied.inspect}" }'

#5 billing message.outreach rules=[]
#6 billing record.plan_change rules=[]
#7 billing money.refund rules=[]
#8 billing record.plan_change rules=[]
```

Four proposals, no citation on any of them. The branch was dead in the demo, so
nobody could read the wording on it without staging a proposal by hand — which
is why it went unexamined until task 5004. The report is correct as filed.

## The fix

The obstacle was ordering: the proposals block ran *before* the rules block, so
no rule id existed yet when `Concierge::Outreach.deliver` staged the outbound
message. Of the two options in the report, **moving the rules block above the
proposals block** is the one that keeps the seed narrated top-to-bottom: rules
are what the agent is told to do, and both the proposals *and* the run
provenance below them cite rules. Splitting the four numbered proposal cards to
stage one of them later would have broken the block that reads as a set.

So the rules block moved up ahead of the proposals block, the three in-force
rules are named where they are created (`blanket, account_specific,
billing_guard = in_force` — the destructuring that used to sit further down),
and proposal #1 carries a citation:

```ruby
Concierge::Outreach.deliver(
  Concierge::Result.new(
    reply_text: "Heads up: the card on file expires before the next invoice date. " \
                "Want me to send Hank a link to update it?",
    rule_ids_applied: [ billing_guard.id ]
  ),
  scope_for(:billing, globex), channel: :email
)
```

The rule it cites is deliberate rather than arbitrary. `billing_guard` is the
one **guard** rule in the demo — *"Never put the word 'guarantee' in a billing
email"* — and it is in force for exactly this proposal's `(billing, Globex)`
scope. The agent claiming it applied a rule that the engine *also* enforces in
code is the sharpest illustration of what the line says: the citation is a
claim, and the guard exists because a model can cite a rule and contradict it in
the same breath (design §10.4).

No proposal was added or removed — the seed still stages the same four cards,
and the summary counts `bin/rails db:seed` prints are unchanged.

## What I ran

**`make verify` — green.**

```
251 files inspected, no offenses detected
578 runs, 2105 assertions, 0 failures, 0 errors, 0 skips
```

`main` at the time of the rebase (`7fcdc56`) runs 577; the one new test brings it
to 578.

**Cross-(agent, account) isolation suite — still green.**

```
$ bin/test test/scope_isolation_test.rb
36 runs, 236 assertions, 0 failures, 0 errors, 0 skips
```

This defect is not itself a boundary crossing — it is demo data that could not
reach a view branch. But a rule citation *can* cross the boundary, so the new
test asserts the seeded citation names a rule in force for the proposal's own
`(agent, subject)` scope rather than merely naming some rule that exists. Two of
the three mutations below are that assertion doing its job.

**The seeded demo, driven by hand.**

```
$ cd test/dummy && bin/rails db:seed && bin/rails server -p 3118
$ curl -s http://127.0.0.1:3118/concierge/admin/proposals | grep -A4 "Rules claimed"
        <dt>Rules claimed</dt>
        <dd>
          the agent says it applied
          <a href="/concierge/admin/rules">#27</a>
          — its own unverified claim, not proof it followed them
```

Screenshots from that running host:

- [`proposals-rules-claimed.png`](proposals-rules-claimed.png) — the approval
  queue. Proposal #17, `message.outreach`, billing: **RULES CLAIMED — the agent
  says it applied #27 — its own unverified claim, not proof it followed them**,
  which is the string the task asked to see.
- [`rules-in-force.png`](rules-in-force.png) — the rules screen the citation
  links to. Rule **#27** is there under Active: `billing`, agent-wide, `guard`,
  *"Never put the word "guarantee" in a billing email."* The link resolves to
  something an operator can go and read.

## The regression test, and its mutation numbers

The test went into `test/dummy_seeds_test.rb`, extending the file PR #23 added
two commits earlier, rather than into a new one. That file already boots the
seeds out of process against a throwaway database — deliberately, because seeds
open with `delete_all` across every table — and memoizes one boot for every test
in the class. A second seeds test in-process would have both duplicated that boot
and contended with the suite's own SQLite file. The inventory the child process
prints now also carries each proposal's cited rule ids alongside the ids actually
in force for that proposal's scope.

One test, `"a seeded proposal cites a rule, and cites one in force for its own
scope"`, asserting both halves together: a demo with no citation leaves the line
dead, and a citation naming an id not in force would render the line while
telling the approver nothing true.

Three mutations applied to `test/dummy/db/seeds.rb`, suite re-run after each,
reverted after each:

| # | Mutation | Result |
|---|---|---|
| 1 | Remove `rule_ids_applied: [ billing_guard.id ]` — the original defect | **1 red.** `no seeded proposal carries rule_ids_applied, so the provenance line on the proposal card and the Slack card can never render in the stock demo` |
| 2 | Cite `[ 9999 ]` — an id no rule has | **1 red.** `proposal #5 (billing) cites rule 9999, which is not in force for its own scope` |
| 3 | Cite `[ blanket.id ]` — a rule belonging to the *other* agent | **1 red.** `proposal #5 (billing) cites rule 7, which is not in force for its own scope` |

Restored after all three: `3 runs, 17 assertions, 0 failures, 0 errors`.

Mutation 1 is the reported defect. Mutations 2 and 3 exist because "give the
proposal a citation" has a lazy form — hardcode any integer, as
`proposals_admin_test.rb` legitimately does for a unit test — that would satisfy
a naive assertion while shipping a demo whose provenance link goes nowhere.

## What I could not verify, and why

- **No live model.** `ANTHROPIC_API_KEY` was unset for the seed runs, so the
  dummy host used its scripted chat. That is fine for this change — the seed
  constructs `Concierge::Result` directly and never asks a model anything — but
  it means I did not observe a real model emitting a `rule_ids_applied` citation
  end to end. The path from a model's citation line to this column is covered by
  `run_provenance_test.rb` with a scripted reply, not by a live call.
- **Slack card rendering was not seen in Slack.** `SLACK_BOT_TOKEN` was unset,
  so the seed's Slack posts went to the dummy host's local logging transport.
  The card is rendered and its provenance block asserted in
  `slack_card_test.rb`, and the seeded proposal now satisfies the condition that
  block is gated on, but no card was viewed in a real workspace.
- **The screenshots were retaken after the rebase.** An earlier pair was taken
  before `7fcdc56` landed and showed the pre-#23 rule text; they were discarded
  rather than committed. The committed pair comes from a host seeded on the
  rebased branch, which is why the rule ids in them (#27) differ from the ids in
  the "reproduced first" listing above (a fresh database numbers them from
  wherever it starts).
