# QA — Slack Approve answers the click; a job performs the action

The defect (ty-4999, filed while building the step-4 Slack seam): `Concierge::Slack::Intake#decide`
called `ApprovalIntake.approve`, which ran `Proposal::Execute` **inline, inside
`POST /concierge/slack/interactions`**. Slack answers that request with an error past about
three seconds, so a host executor that calls a payment provider or an external API made Slack
tell the operator their decision had failed — for a decision that had landed *and* executed.

## Reproduced first, against a genuinely running server

`cd test/dummy && bin/rails db:prepare && bin/rails db:seed`, then `bin/rails server -p 3199`
with `SLOW_EXECUTOR=4` — a knob added to the dummy host's `record.plan_change` executor so a
slow host executor can be seen by hand (every real one that talks to a payment provider is
this, without the env var). The click is a genuinely signed interactivity POST: the same
HMAC over the raw body Slack sends, verified by `Concierge::Slack::Signature` before a byte
of the payload is read. Nothing is stubbed.

**Before — `main` (`2537652`) + a 4-second host executor.** Rails' own log, `tmp/server-before.log`:

```
Started POST "/concierge/slack/interactions" for 127.0.0.1 at 2026-07-25 23:38:55 -0500
Completed 200 OK in 4035ms (ActiveRecord: 4.5ms (9 queries, 0 cached) | GC: 17.8ms)
```

```
proposal #6 billing/account#5 record.plan_change {"from"=>"enterprise", "to"=>"pro", ...}
POST /concierge/slack/interactions -> 200 in 4.051s (Slack's budget is ~3s: BLOWN)
row immediately after the response: state=executed
tenant plan immediately after:      pro
```

4.035 seconds. Slack would have shown Dana an error, and the plan change would have happened
anyway — the row right, the human told it was wrong.

**After — this branch, same executor, same click:**

```
Started POST "/concierge/slack/interactions" for 127.0.0.1 at 2026-07-25 23:39:46 -0500
[ActiveJob] Enqueued Concierge::ProposalExecutionJob (Job ID: c081f178-…) to Async(default)
            with arguments: 6, {:by=>"dana@acme.test",
            :slack=>{"channel"=>"C0BILLINGDEMO", "ts"=>"1785040478.624641", "user"=>"UDANA"}}
[dummy] slack chat.update -> C0BILLINGDEMO
Completed 200 OK in 27ms (ActiveRecord: 6.0ms (4 queries, 0 cached) | GC: 5.3ms)
…
[Concierge::ProposalExecutionJob] [c081f178-…] [dummy] slack chat.update -> C0BILLINGDEMO
[Concierge::ProposalExecutionJob] [c081f178-…] Performed … in 25058.77ms
```

```
proposal #6: POST -> 200 in 0.035s
```

**4035ms → 27ms.** That run used `SLOW_EXECUTOR=25` so the window was easy to observe by
hand: the endpoint answered in 27ms, the job took the full 25 seconds, and the card was
updated twice — once inside the request, once by the job.

## The two card updates

`block-kit-card-updates.json` holds both payloads for proposal #6. The decision section is
the whole difference:

```
1 · in the request  :hourglass: *Approved* by dana@acme.test at 2026-07-26 04:39:46 UTC
                    — queued to be performed — this card updates when it is
2 · from the job    :white_check_mark: *Executed* at 2026-07-26 04:39:46 UTC by dana@acme.test
                    Approved by dana@acme.test
```

Both cards drop the buttons, so a second person cannot click Approve on a decision that has
already been made. The first card deliberately says *queued*, not *executing* or *done in a
moment*: if nothing ever runs the queue, the card has said so.

Rendered with the same `Concierge::Slack::Card` the server called. The dummy host's offline
Slack transport logs only the method and channel, not the body, so the payloads are
reproduced from the live seeded row rather than intercepted off the wire — see
*What I could not verify* below.

## The refusal path, live

Deferring execution must not lose a refusal. Reset #6 to `proposed` after the plan had
already moved to `pro`, so its precondition digest was stale, and clicked Approve again:

```
proposal #6: POST -> 200 in 0.009s
[Concierge::ProposalExecutionJob] [7e6a3a1f-…] [dummy] slack chat.postEphemeral -> C0BILLINGDEMO
```

The click succeeded — the decision *did* land, and that is all it claimed. The job found the
mismatch and whispered *"Proposal #6 was approved but not performed (precondition failed): …
It is waiting in /concierge/admin/proposals"* back to the person who clicked.

| # | Screenshot | What it shows |
|---|------------|---------------|
| 01 | `01-queue-before-the-click.png` | `/concierge/admin/proposals`: **Awaiting a human (3)**, #6 `record.plan_change` `enterprise → pro` carded in `C0BILLINGDEMO`. **Approved — not performed yet (0)**. |
| 02 | `02-queue-decision-landed-executor-still-running.png` | The same page loaded immediately after the click, while the 25-second executor was still running. The queue is serving normally; #6 has left "Awaiting a human". |
| 03 | `03-admin-slack-cards.png` | `/concierge/admin/slack` — which cards posted, which the daily cap suppressed. Unchanged by this PR; included because the seam's other surface should be seen to be untouched. |
| 04 | `04-deferred-refusal-lands-in-the-queue.png` | The refusal path: **Approved — not performed yet (1)** with #6, `dana@acme.test`, *"the state this proposal assumed has changed since it was drafted (3b66d1de… → 6f295492…)"*, and a **Retry execution** button. Exactly where step 3 put every unperformed approval. |

All 1280×900, full page, Playwright MCP against `bin/rails server -p 3199` on the seeded dev
database.

## Tests

`make verify` — rubocop 246 files, no offenses; **545 runs, 1952 assertions, 0 failures, 0
errors, 0 skips** (532 runs on `main`, so **13 new tests**).

**Mutation check.** Reverted `Intake` to the old inline call
(`ApprovalIntake.approve(proposal, by: actor)` with no deferral) and re-ran the suite:
**9 failures**, in three files —

```
Concierge::SlackIntakeTest#test_Approve_writes_the_decision_synchronously_and_hands_the_execution_to_a_job
Concierge::SlackIntakeTest#test_a_slow_host_executor_cannot_blow_Slack's_three-second_interactivity_budget
Concierge::SlackIntakeTest#test_the_queued_job_executes_it,_and_only_then_does_the_card_say_it_happened
Concierge::SlackIntakeTest#test_an_approval_whose_execution_is_refused_is_not_reported_as_a_success
Concierge::SlackIntakeTest#test_the_job_re-checks_the_gate_at_the_moment_it_runs,_not_at_the_moment_of_the_click
Concierge::SlackIntakeTest#test_Correct_edits_the_payload,_keeps_the_original,_and_approves_the_edit
Concierge::ScopeIsolationTest#test_an_execution_deferred_to_a_job_performs_into_its_own_cell_and_no_other
SlackEndpointsTest#test_a_signed_Approve_click_decides_the_proposal_and_queues_the_execution
SlackEndpointsTest#test_the_endpoint_answers_Slack_well_inside_its_budget_even_with_a_slow_executor
```

Reverted, green again.

**The load-bearing invariant.** `test/scope_isolation_test.rb` passes (35 runs, 229
assertions) and was *extended*, not tested beside: deferring execution puts a bare proposal
id on a queue and lets it cross a process boundary, which is a new way for one cell's work to
reach another's. `an execution deferred to a job performs into its own cell and no other`
approves `billing/Acme` through the Slack seam, performs the queued job, and asserts the
delivery landed only in `billing/Acme` — not `billing/Globex`, not `csm/Acme` — that
Globex's proposal is still `proposed`, and that the card the job redrew went back to its own
agent's channel. The job carries no scope of its own; `Proposal::Execute` re-resolves the
`(agent, account)` pair from the row.

## What I could not verify

- **A real Slack workspace.** With no `SLACK_BOT_TOKEN` the dummy host answers the Web API
  with a local stand-in that logs the call. So the *sequence* of Web API calls is real
  (two `chat.update`s, one `chat.postEphemeral`, in the right order, from the right
  processes) and the payloads are the real `Card` output, but nothing was rendered by Slack
  and no human clicked a real button. The three-second budget itself is Slack's documented
  behaviour, not something this QA measured against Slack — what it measured is how long the
  endpoint takes, which is the half in our control.
- **A real LLM.** `ANTHROPIC_API_KEY` was unset, so the dummy host ran its scripted chat.
  Nothing in this change touches the model path — the proposals are seeded — but this was not
  exercised against a live model.
- **A production queue.** The dummy host uses ActiveJob's default `:async` adapter, so the
  job ran in the server's own thread pool. Behaviour under Solid Queue / Sidekiq (a separate
  worker process, real retries, a queue that is down) was not exercised. The job is written
  for it — it takes only a proposal id and strings, and `Proposal::Execute`'s conditional
  `UPDATE` makes a retry safe — and `running twice performs the action once` covers the retry
  in the suite, but no separate worker process was run.
- **The intermediate state in the admin queue.** There isn't one to screenshot:
  `Proposal::Execute` claims the row (marking it `executed`) *before* dispatching, which is
  the pre-existing at-most-once behaviour and is untouched here. So `/concierge/admin/proposals`
  shows the same thing before and after this change, and screenshot 02 shows the queue serving
  normally mid-execution rather than a new state. The visible change is on the Slack card.
