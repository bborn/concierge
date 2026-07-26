# QA — the Acme demo host

Screenshots taken with the Playwright MCP browser against a genuinely running
server (`cd test/dummy && bin/rails db:seed && bin/rails server -p 3111`), with
`ANTHROPIC_API_KEY` **unset** — so every agent reply below is the offline
stand-in answering over the real prompt, not a real model. See "What I could not
verify" at the bottom.

| # | Screenshot | What it shows |
|---|---|---|
| 01 | `01-sign-in-picker.png` | The picker: every seeded user with their tenant and plan. No passwords. |
| 02 | `02-changelog-acme.png` | The product, signed in as Dana. One draft, nothing published — mid-onboarding, which is what the CSM's charter is about. Unread badge on Inbox. |
| 03 | `03-chat-with-kit.png` | A two-turn exchange with Kit, posted to `POST /concierge/accounts/:id/chat` with the page's CSRF token. The reply knows there is 1 draft and the plan is `pro` because the Snapshot said so. |
| 04 | `04-inbox-unread-outreach.png` | The inbox after "Kit, take a look": a fresh proactive message at the top, the seeded ones below, Bill's billing note under its own name, and the provenance link ("see what Kit was told — run #35"). |
| 05 | `05-account-before-request.png` | The account page: plan, both agents and their authority, the scheduled check-in. |
| 06 | `06-plan-change-requested.png` | The gated path from the customer's side — "Your request is with our team", proposal #18, `record.plan_change`, gate `human_approval`. The plan is still `pro`. |
| 07 | `07-approval-queue.png` | The same request in `/concierge/admin/proposals` (the engine's own stylesheet — the host does not borrow it). |
| 08 | `08-admin-approved.png` | "Proposal #18 executed." |
| 09 | `09-plan-changed-after-approval.png` | Back in the product: the plan **really is** `enterprise`, in the header, the pill and the plan card, attributed to `operator@acme.test`. |
| 10 | `10-talk-to-a-human.png` | A `Concierge::Handoff` open: Kit marked "stepped back", the composer replaced by an explanation, and a way to hand the thread back. |
| 11 | `11-inbox-dark-mode.png` | The same inbox with `prefers-color-scheme: dark`. |

## What I could not verify

- **A real model.** No `ANTHROPIC_API_KEY` was available in this environment, so
  every reply in these screenshots came from `Dummy::ScriptedChat`. What *is*
  verified is that the prompt path a real model would receive is assembled and
  correct — `test/integration/host_chat_widget_test.rb` asserts, on the prompt
  produced by the widget's own POST, that it carries the persona line, the
  product brief, this account's Snapshot (`published_changelogs: 0`), its
  memory, and the rules in force, and that an `AgentRun` provenance row is
  written with the injected rule ids. The agent-tool list is asserted to be the
  CSM's and not billing's.
- **Tool-call chips with a real model.** The widget reads tool calls back from
  the host's own `tool_calls` table (`GET /agent/activity`) because a RubyLLM
  reply's tool calls land on the messages *before* the final one. The endpoint is
  tested against rows written by hand; it has never been driven by a live
  tool-using turn.
- **Turbo/ActionCable surfacing.** `Concierge::Channel::InApp` broadcasts through
  `config.in_app_broadcaster`; this host persists the message rather than pushing
  it to an open page, so the unread badge appears on the next request rather
  than live.

## Known gap, filed separately — since closed

> **Update (2026-07-26):** fixed by task 5003 — the engine now has
> `config.authorize_subject`, and the chat and handoff endpoints fail closed
> without it. See `docs/design/qa/5003-chat-authorization/`. Task 5005 then split
> the operator endpoints onto their own hook, `config.authorize_operator`, so
> that a tenant-match answer no longer lets a customer seize their own thread —
> see `docs/design/qa/5005-operator-authorization/`.


`POST /concierge/accounts/:subject_id/chat` is unauthenticated — the engine has no
equivalent of `config.authenticate_admin` for it, so a signed-in user could hand-
craft a POST for another account's `subject_id`. The demo host never renders one,
and every *host* surface is tenant-scoped (`test/integration/host_isolation_test.rb`),
but the engine endpoint predates this PR and is unchanged by it. Filed as its own
ty task rather than fixed here.
