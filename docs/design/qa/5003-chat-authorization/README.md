# QA — host authorization for the engine's per-account endpoints (task 5003)

Everything below was done against a genuinely running dummy host
(`cd test/dummy && bin/rails db:prepare && bin/rails db:seed && bin/rails server -p 3111`)
with `ANTHROPIC_API_KEY` **unset**, so the replies come from `Dummy::ScriptedChat`
over the real prompt — see "What I could not verify".

Seeded ids used throughout: **Acme Corp is tenant 4** (Dana, `pro`, nothing
published), **Globex is tenant 5** (Hank/Lena, `enterprise`, 3 entries published).

## The reproduction, first

| # | Screenshot | What it shows |
|---|---|---|
| 00 | `00-before-the-fix-globex-answers.png` | **The bug.** Signed in as Dana at Acme — her own page says *"Nothing published yet"* — with the widget's `data-chat-url` retargeted at `/concierge/accounts/5/chat` from devtools. Kit answers *"3 entries published on the enterprise plan"*: that is **Globex's** snapshot, assembled into a prompt and read back to somebody at another company. Taken with `app/controllers` reverted to `origin/main` on the same running server. |

Reproduced over HTTP too, before writing any fix: `POST /concierge/accounts/5/chat`
as Dana returned `200` with Globex's state in the prompt, and
`POST /concierge/accounts/5/handoff` seized Globex's CSM thread as
`dana@acme.test`. Both are in the first commit's test failures below.

## After the fix

| # | Screenshot | What it shows |
|---|---|---|
| 01 | `01-kit-answers-her-own-account.png` | Dana's own account, untouched: the widget posts to `/concierge/accounts/4/chat` and Kit answers with *Acme's* state (1 draft, `pro`). The gate refuses the neighbour without costing the customer their agent. |
| 02 | `02-tampered-subject-id-refused.png` | The same tampered request as 00, now refused — the widget renders the engine's `403` body as an error bubble: **"not authorized for this account"**. Same page, same session, same CSRF token. |

`transcript.txt` is the raw curl session behind those screenshots — signing in as
Dana, then every endpoint the change touches:

```
her own account's chat                          200 (a real reply)
Globex's chat, as the :csm agent                403 {"error":"not authorized for this account"}
Globex's chat, as the :billing agent            403
seizing Globex's operator thread                403
releasing Globex's operator thread              403
an account id that does not exist               403  ← same answer, so it is not an id oracle
signed out entirely (valid CSRF token)          403
```

## The fail-closed default, on the real server

With `c.authorize_subject` removed from the dummy host's config and the app
reloaded, `POST /concierge/accounts/4/chat` — Dana's *own* account — is refused,
and `test/dummy/log/development.log` says why:

```
[Concierge] Refused a request for an account because config.authorize_subject
is not set. The engine cannot know your app's session shape, so it fails
closed rather than answer with an account's memory, rules and snapshot to
whoever asked. Set it in your initializer, next to config.authenticate_admin:

  config.authorize_subject = lambda do |controller, scope|
    user = User.find_by(id: controller.session[:user_id])
    user && user.tenant_id.to_s == scope.subject.id.to_s
  end

Filter chain halted as :authorize_subject! rendered or redirected
```

The hook was put back afterwards; the committed config is unchanged from the
version the tests run against.

## Automated

- `make verify` — rubocop (237 files, no offenses) + `bin/test`: **503 runs, 1766
  assertions, 0 failures, 0 errors**.
- **Mutation check.** Replacing the body of `ScopedEndpoint#authorize_subject!`
  with `true` — exactly the pre-fix behaviour, no host authorization at all —
  turns **11 tests red** (9 failures, 2 errors): 6 in
  `test/integration/host_isolation_test.rb` (the cross-(agent, account) isolation
  suite, host-surface half) and 5 in
  `test/integration/subject_authorization_test.rb`. Reverted after measuring.
- The isolation invariant itself (`test/scope_isolation_test.rb`, 28 tests) still
  passes untouched — this change adds a gate in front of the HTTP surface, it does
  not move where state is keyed.

## What I could not verify

- **A real model.** No `ANTHROPIC_API_KEY` in this environment, so every reply in
  these screenshots is `Dummy::ScriptedChat` answering over the real assembled
  prompt. That is enough for this change — the defect is *whose* state gets
  assembled, and the "before" screenshot shows the wrong account's snapshot
  reaching the prompt regardless of who renders it — but no live turn was made.
- **A host with real authentication.** The dummy app has no passwords; its hook
  reads `session[:user_id]`, which is the same seam a real host would use but a
  much smaller one than, say, Devise plus an org-membership check.
- **Existing hosts upgrading.** There are none — the gem is unreleased at 0.1.0,
  which is why this fails closed rather than warning and allowing. A released gem
  would need a deprecation window instead; the filed task left that decision open
  and this is the call made, stated plainly here so it can be reversed cheaply.
- **The operator endpoints' authorization *policy*.** The engine now asks the host
  before a seize/release/send-as-human, but it is still one hook for both the
  customer-facing chat and the staff-facing operator endpoints; a host that wants
  "customers may chat, only staff may seize" writes that as a clause in the hook
  (the controller and `scope.agent_slug` are both in reach) rather than getting a
  separate seam. Filed as a follow-up rather than guessed at here.
