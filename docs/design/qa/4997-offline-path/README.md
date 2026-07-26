# QA — the offline path, in the engine (task 4997)

`Concierge::Run` raised `RubyLLM::ConfigurationError` on a host with no API key,
contradicting the documented offline path. PR #5 worked around it in the dummy
app with a placeholder key; this change puts the answer in the engine and takes
the placeholder back out.

## Reproduced first, on this branch's base

```
cd test/dummy
env -u ANTHROPIC_API_KEY bin/rails runner '
  RubyLLM.config.anthropic_api_key = nil          # what a real keyless host has
  Concierge::Conversation.delete_all
  subject = Concierge.config.account.find_subject(Tenant.first.id)
  Concierge::Run.proactive(subject, instruction: "hi")'
```

```
RAISED RubyLLM::ConfigurationError: Missing configuration for Anthropic:
anthropic_api_key. Set these keys on RubyLLM.config before using this provider.
```

The report's first suggested fix — *don't set `chat.provider`* — was checked and
does **not** work. Both branches of `RubyLLM::Models.resolve` instantiate the
provider (`models.rb:154-183`), and `Provider#initialize` calls
`ensure_configured!`. Leaving the provider unset only routes to the other branch:

```
Chat.new.tap { |c| c.model = "claude-sonnet-4-5" }.save!
#=> RubyLLM::ConfigurationError (same error, no provider set)
```

So no combination of `assume_model_exists` / `provider` gets a `Chat` **record**
created without credentials. The engine has to decide for itself, which is what
`Concierge::ProviderCredentials` now does — it asks RubyLLM's *class-level*
`Provider.configured?(config)`, which reads config without building anything.

## After the fix — same command, no key anywhere

```
ok?=true conversations=0 reply="You haven't published a changelog entry yet, and …"
```

And the two flanking cases, both checked by hand:

| host state | outcome |
|---|---|
| no key, scripted `chat_factory` (documented offline path) | `ok? = true`, no `Conversation` row, warning logged |
| no key, default `chat_factory` (no offline seam) | `ok? = false`, `error = RubyLLM::ConfigurationError` — **not** raised, **not** falsely green |
| key present | unchanged: `persisted=true provider=anthropic conversations=1` |

## In the running dummy host, with `ANTHROPIC_API_KEY` genuinely unset

`env -u ANTHROPIC_API_KEY bin/rails server` — and with the placeholder key now
removed from `test/dummy/config/initializers/ruby_llm.rb`, so this is the same
state a real keyless host is in.

1. **`01-reactive-chat-no-api-key.png`** — signed in as Dana, asked Kit "how do I
   publish my first changelog?" through the Kit widget. It answers, from the
   scripted chat, over the real assembled prompt (it knows she has 1 draft and is
   on `pro`). Before the fix this request 500'd.
2. **`02-proactive-outreach-no-api-key.png`** — "Kit, take a look", i.e. the exact
   `Concierge::Run.proactive` entry point from the bug report. It ran, delivered
   in-app outreach, and linked its provenance row (run #25).
3. **`03-run-provenance-offline.png`** — both turns recorded at
   `/concierge/admin/runs`, `status: ok`, model, snapshot digest, and the rules
   that were injected. The audit trail is intact without a persisted chat.

Server log, three times over that session:

```
[concierge] no credentials configured for anthropic; running without a persisted
conversation. Chat history will not be saved until the provider's API key is set.
```

Database afterwards — the degrade is honest about itself:

```
conversations=0  recent_runs=[["reactive","ok",nil], ["proactive","ok",nil]]
```

## Tests

`make verify`: rubocop 243 files clean, **524 runs / 1842 assertions / 0
failures** on top of `origin/main` at 5efe05a.

Mutation check (revert `lib/` + the dummy initializer to `main`, keep the new
tests): **16 red** — 1 failure, 15 errors.

- `ProviderCredentialsTest` ×6 (the module does not exist)
- `ChatResolverTest` ×3 — resolves without credentials; yields no chat record and
  no conversation; credentials appearing later restore persistence
- `RunTest` ×3 — proactive answers with no credentials; no-credentials-and-no-
  offline-chat is a failed `Result`; that run records failed provenance
- `ScopeIsolationTest` ×3 — the load-bearing suite, extended rather than tested
  beside: the uncredentialed path hands no cell a chat and none a neighbour's; an
  uncredentialed run keeps every cell's prompt and provenance its own;
  credentials returning still yields one conversation per (agent, account)
- `OfflineBootTest` ×1 — the boot test, which fails on the *dummy initializer*
  mutation specifically (verified separately by re-adding the placeholder key:
  `a placeholder anthropic key was installed at boot`)

`test/offline_boot_test.rb` is the anti-masking guard. Every other test runs in a
process where `test_helper` sets `ANTHROPIC_API_KEY` on purpose, so none of them
can observe a genuinely keyless boot — which is exactly how a placeholder key hid
this for a phase. It shells out to `bin/rails runner` in `test/dummy` with the
variable removed from the child environment and asserts no initializer invented a
credential. It queries nothing, so it needs no seeded database and does not
contend with the suite's own SQLite file.

## What I could not verify

**Nothing here was run against a real Anthropic model.** I have no
`ANTHROPIC_API_KEY` in this environment. Concretely:

- The **offline** path is verified end to end, in the UI and in the suite.
- The **credentialed** path is verified only as far as *record creation*: with a
  fake key exported, `ChatResolver` persists the `Chat` and the `Conversation`
  exactly as before (`persisted=true provider=anthropic conversations=1`). That
  proves the new `uncredentialed?` branch is not taken when a key is present, and
  that pinning still works.
- What is **not** verified is a live `chat.ask` round-trip against Anthropic. This
  change does not touch the request path — it only decides whether a `Chat` record
  is created before it — but I am stating the gap rather than implying otherwise,
  since that exact gap is what hid the ActiveStorage bug in #14.
