# QA — `config.subject_label`: naming a subject for the human reading the queue

Task 5026. Every engine surface named a subject by its key (`account#135`) —
correct internally, unreadable to the operator the queue is for. This adds one
host hook that answers for all of them.

Screenshots below are from a genuinely running `test/dummy` (`bin/rails server`,
`ANTHROPIC_API_KEY` unset, so the scripted offline chat), against seeded data:
three tenants — Acme Corp (`account#4`), Globex (`account#5`), Initech
(`account#6`).

## Reproduction, first

Before touching anything, five admin screens were rendered against a real
request in an integration harness and asserted to contain `account#<id>` and to
contain no tenant name at all:

```
memories     -> account#1
deliveries   -> account#1
routines     -> account#1
runs         -> account#1
proposals    -> account#1
```

Confirmed: the report is accurate, on every surface it names.

## Before / after

| # | Shot | What it shows |
|---|------|---------------|
| 01 | `01-before-proposals.png` | Hook unset. `AGENT: billing · account#5` — the queue names a customer by primary key. |
| 02 | `02-before-runs.png` | Same, per run row. |
| 03 | `03-before-memories.png` | Same, per memory row. |
| 04 | `04-after-proposals.png` | Hook set. `AGENT: billing · Globex`. |
| 05 | `05-after-runs.png` | Runs index, ACCOUNT column now names the tenant. |
| 06 | `06-after-memories.png` | Memories index. |
| 07 | `07-after-deliveries.png` | Delivery audit log. |
| 08 | `08-after-rules.png` | Rules — account-scoped rules name the account. |
| 09 | `09-after-slack.png` | Slack cards screen, CASE column. |
| 10 | `10-after-routines.png` | Routines. |
| 11 | `11-after-agents.png` | Agents — the last-handback line reads `Initech`. |

## The failure modes, also on the running server

| # | Shot | What it shows |
|---|------|---------------|
| 12 | `12-raising-label-falls-back.png` | `config.subject_label` replaced with `->(_) { raise }`. Every screen still 200s and falls back to the key. |
| 13 | `13-markup-label-renders-inert.png` | Label returns `<script>alert('pwned')</script> Bell & Co`. It renders as visible, inert text — ERB escaping, no `html_safe` anywhere on this path. |

With the raising lambda, all eight screens returned HTTP 200 and printed the
key, and the log carried exactly one line per request:

```
[concierge] config.subject_label raised for account#5 (RuntimeError: the host's
Property lookup is broken) — falling back to the subject key
```

16 requests → 16 lines. Not one per row.

## What I ran

- `make verify` — rubocop (271 files, no offenses) + `bin/test`: **707 runs,
  2900 assertions, 0 failures, 0 errors**. Baseline on `main` before this change
  was 676 runs / 2622 assertions, also green.
- The demo host by hand as above (seeded, offline scripted chat).

## Mutation testing — do the new tests actually fail against the old code?

Each mutation applied alone to `lib/concierge/subject_label.rb` (or the helper),
full suite run, then reverted:

| Mutation | Red |
|---|---|
| A — the hook never applies (i.e. exactly today's behaviour restored) | **18** (17 failures, 1 error) |
| B — no `rescue`: a raising host lambda escapes into the controller | **6** (1 failure, 5 errors) |
| C — no memoization: the host is asked once per row | **3** |
| D — a blank label is taken at face value instead of falling back | **3** |
| E — log every failure instead of once per resolution | **1** |
| F — the helper wraps the label in `html_safe` | **1** |

Suite is green again after reverting all six.

## What I could not verify, and why

- **No live model.** `ANTHROPIC_API_KEY` was unset, so the demo host ran its
  scripted chat. Nothing in this change touches the model path — the label is
  never in a prompt, only in rendered HTML and Slack block text — but I did not
  exercise an online run, and I am not claiming to have.
- **No real Slack.** The Slack card and digest assertions are against the test
  transport (`Concierge::Test.configure_slack!`) and the JSON blocks it captured,
  not a posted message in a workspace. That is the same seam every other Slack
  test in this repo uses.
- **No RIC Dashboard.** The reporting host is not in this repo; I verified the
  hook shape matches the one in the ticket
  (`->(subject) { Property.find_by(id: subject.id)&.business_name }`) and works
  against the dummy host's equivalent, but the real integration is untested here.

## One deliberate deviation, stated plainly

Back-compat is byte-for-byte, and two call sites never used the canonical
`type#id` shape:

- the agents screen's last-handback line has always read `account 6` (a space,
  inside a `<code>`);
- the Slack card and digest have always read `account #5` (a space before `#`).

Rather than normalize those — which would change what an un-hooked host sees —
each passes its own historical wording as an explicit `fallback:`. So a host that
sets no hook sees exactly what it saw before, on every surface, and a host that
sets one sees its label on every surface.
