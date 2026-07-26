# QA — Retry asserts what it is allowed to act on

The defect (ty-5012, filed while adding the `execute: false` seam in #22): every other
transition on `Concierge::ApprovalIntake` asserts what it may act on — `approve`/`reject`/
`correct` call `assert_open!`, `record_execution` refuses anything not `approved?`.
`retry_execution` asserted only that the actor was a human, so it wrote to any row it was
handed.

## Reproduced first, against the running dummy host

`cd test/dummy && bin/rails db:prepare && bin/rails db:seed && bin/rails server -p 3212`, on
`main`'s `lib/concierge/approval_intake.rb` (`git stash`ed this branch's change and restarted
the server, so the code under the screen was genuinely `main`'s). Proposal #9 is a real
rejection made through the admin screen, with a reason.

**Before — `main` (`36e70a8`, this branch's merge-base at the time of the run):**

```
before: #9 state=rejected rejected_reason="customer changed their mind" queued=nil
retry_execution(execute: false) -> :approved
after:  state=rejected queued=2026-07-26 06:58:01.948789000 UTC
card says: [":x: *Rejected* by dana@acme.test at …", "> customer changed their mind"]
hand_off_execution would queue it? false
=> nothing will ever call Proposal::Execute on it, so the stamp is permanent: true
```

Three things are wrong in six lines. It returned `:approved` about a **rejected** row. It
stamped `execution_retry_queued_at`, which is the row telling every surface a retry is coming.
And the only thing that clears that stamp is `Proposal::Execute` — which a deferring surface
never calls here, because its guard is `proposal.approved? && !proposal.human_execution?`
(`Slack::Intake#hand_off_execution`). So the stamp is permanent, on a proposal nobody will ever
perform.

The ticket called this latent rather than visible, and that is still true today: the admin
queue's `unexecuted` scope is `approved`-only, and `Slack::Card#decision_lines` takes the
`rejected?` branch (visible in the third line above) before it ever reaches
`unexecuted_reason`. It is a wrong row, not a wrong screen — until a third surface reads the
column.

**After — this branch, same server, same row:**

```
retry_execution(execute: false) -> REFUSED: proposal 9 is rejected, so there is no approved action to retry
after:  state=rejected queued=nil rejected_reason="customer changed their mind"
```

Refused, and the row is exactly as the human left it.

## The part that *is* visible on a screen today

A non-approved row has no Retry button — but a **stale page does**. Two operators, both with
the queue open on the same approved-and-failed proposal; the first clicks Retry and it
succeeds; the second clicks the button still on their screen.

| # | Screenshot | What it shows |
|---|------------|---------------|
| 00 | `00-before-main-tells-the-operator-it-was-not-executed.png` | `main`. The second click gets **"Proposal #11 was approved but not executed (already executed)."** — a sentence that contradicts itself, from `flash_for`'s else-branch, *after* the retry had already cleared the row's columns. |
| 01 | `01-the-row-a-retry-is-for-next-to-the-row-it-is-not.png` | This branch, the queue before either click: #10 approved with a `Net::ReadTimeout` and a Retry button, #9 and #8 rejected below in Decided. The Retry affordance is unchanged for the row it is actually for. |
| 02 | `02-the-second-click-is-refused-by-name-and-writes-nothing.png` | This branch, the same second click: **"proposal 10 is executed, so there is no approved action to retry"** — the seam's `GateError`, in `record_execution`'s shape, and the row untouched. |

Both are alerts an operator can act on; the integration test
(`test/integration/proposals_admin_test.rb`, "the Retry button on a row nobody approved is
refused, and says why") now records which one is intended, and why, since the ticket asked for
that decision to be written down rather than inferred.

## Tests

`make verify`, rebased onto `origin/main` (`f16750c`): **611 runs, 2265 assertions, 0 failures,
0 errors** (rubocop clean, 255 files).

Mutation check — deleted the `assert_retryable!(proposal)` call from `retry_execution` and ran
the whole suite (re-run after the rebase, so these are the current numbers):

```
611 runs, 2243 assertions, 3 failures, 0 errors
  ApprovalIntakeTest#test_retrying_refuses_every_row_that_has_no_approved_action_to_re-attempt
    retry wrote to a proposed row. Concierge::Proposal::GateError expected but nothing was raised.
  ApprovalIntakeTest#test_a_deferred_retry_cannot_leave_a_stamp_on_a_row_nothing_will_ever_execute
    Concierge::Proposal::GateError expected but nothing was raised.
  ProposalsAdminTest#test_the_Retry_button_on_a_row_nobody_approved_is_refused,_and_says_why
    -"proposal 1 is rejected, so there is no approved action to retry"
    +"Proposal #1 was approved but not executed (not approved)."
```

Three red, and **no other test went red** — nothing in the tree depended on retry writing to a
row it had no business writing to.

Cross-(agent, account) isolation suite: `bin/test test/scope_isolation_test.rb` — **38 runs,
249 assertions, 0 failures**. Its existing "a retry deferred to a job re-attempts its own cell
and no other" already covers the boundary; this defect is a *state* guard, not a boundary
crossing, so the suite was run rather than extended. Adding a state assertion to it would have
put a non-isolation property in the one suite whose subject should stay exactly one thing.

## What I could not verify

- **No live model.** `ANTHROPIC_API_KEY` is unset, so the dummy host ran its scripted chat
  throughout. Nothing on this path touches a model — the proposals were made through
  `Concierge::Proposal.propose` and the seam, and the executor is the dummy's own
  `record.plan_change` — but the online path was not exercised and this change does not
  claim to have been.
- **No Slack.** There is no Retry button on a Slack card in the tree yet; `Slack::Intake`
  handles Approve/Reject/Correct/Mark-executed only. The permanence argument above uses
  `hand_off_execution`'s actual guard (`approved? && !human_execution?`), evaluated against the
  real row, rather than a Retry surface that does not exist. When one is added, it earns this
  refusal for free — it goes through the same seam.
- **The `expired` case is refused by state, not by expiry.** An `approved` row whose
  `expires_at` has passed is still accepted here, exactly as `record_execution` accepts it;
  `Proposal::Execute` refuses it with `:expired` and clears the stamp. Changing that would be a
  second policy decision, and this ticket asked for one.
