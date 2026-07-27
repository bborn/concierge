# QA — a registry that cannot answer is not a host with credentials

The defect (ty-5014, filed while adding the run→reply link in #25):
`Concierge::ProviderCredentials.provider_for` rescued a registry miss to `nil`, and
`configured?` reads `nil` as "Concierge has no opinion" — i.e. **credentials are fine**. The
docstring said an *unknown* model answering true was deliberate, and it is. The bug was which
models counted as unknown.

RubyLLM 1.16 memoizes one registry per process (`Models.instance`) and picks its source the
first time anything asks: the host's `models` table when that table has rows, the bundled JSON
otherwise (`models.rb#load_models`). `acts_as_model` installs that ActiveRecord source at
class-definition time — so on the recommended Rails setup the live registry holds **only the
handful of models the host has actually talked to**, and `Models.find` raises
`ModelNotFoundError` for every other model in existence. "Not in this host's table" was being
read as "no such model", which is how a host with no API key at all got told its credentials
were fine.

## Reproduced first

A scratch test (deleted before commit) followed the ticket's repro sketch — one `Model` row,
drop the memoized registry, ask about anything else:

```
registry size: 1
provider_for(gpt-4.1-nano): nil
OPENAI key: nil
configured?(model: gpt-4.1-nano): true      # ← no key anywhere, "configured"
```

And the consequence the ticket predicted — `ChatResolver#uncredentialed?`, the #14 gate that
makes a keyless host degrade instead of raising, stops firing:

```
ChatResolver RAISED: RubyLLM::ModelNotFoundError: Unknown model: "claude-sonnet-4-5" …
Concierge::Run.reactive → the same error escapes Run entirely (not a failed Result)
```

Both confirmed. The report is accurate.

## The change

One method. `provider_for` asks the active registry and, on a miss, asks RubyLLM's **bundled
JSON** as its own registry instance — complete, offline, and the same data RubyLLM itself falls
back to. Only a model *neither* registry knows is genuinely unknown, and there the deliberate
`true` still stands.

Three decisions are load-bearing:

- **The bundled registry is a separate instance, never `RubyLLM.models`.** Asking must not
  repair, replace, or otherwise disturb the registry the host chose — swapping the process-wide
  memo would change which models the host's own `acts_as_chat` can resolve. There is a test
  that asserts `Models.instance` is the same object afterwards.
- **The ticket's other suggestion — fall back to `Concierge.config.default_provider` — was
  considered and rejected.** `ChatResolver` already passes `provider:` explicitly, so it buys
  nothing there; and for a genuinely unknown id it makes things *worse*. A host that typo'd its
  model would get a silent degrade instead of RubyLLM's `Unknown model: "claude-sonnet-4.5"`,
  which is the error that actually names the typo. The registry answer beats the host default
  where both exist, and "unknown" keeps meaning unknown-to-RubyLLM.
- **The rescue stays broad, per registry.** A host may point `model_registry_source` at
  something broken; that registry has no answer, and the caller tries the next one, rather than
  a config mistake becoming an exception in a credentials check.

`configured?` itself is unchanged.

## What was run

- `make verify` — rubocop clean (**264 files**), **638 runs, 2408 assertions, 0 failures, 0
  errors**.
- Cross-`(agent, account)` isolation suite **extended rather than tested beside**: the existing
  uncredentialed-grid cases prove the degrade keeps the four cells apart, but both inherit the
  dummy's `default_provider` and so never asked through the model at all — the bug was invisible
  to them. `a partial registry does not switch the degrade off under any cell` asks the same
  isolation question in the configuration where the degrade was switched off.
- **The suite no longer depends on the test_helper registry pin.** #25 pinned the bundled JSON
  to kill the order-dependence, which was right, but pinning only ever hid the flake — the
  production defect was there either way. With the fix, `make verify` passes with that line
  removed, on seeds 1 / 4242 / 99999 (638 runs, 0 failures each). The pin stays, because "every
  run asks the same registry" is still worth having; the comment there now says which of the two
  jobs it is doing. Tests that need the host's real, partial registry ask for it in scope via
  `with_partial_model_registry`, so the behaviour is covered rather than papered over.

### Mutation testing (fix reverted, suite re-run, restored)

| Mutation | Red |
|---|---|
| `provider_for` back to `RubyLLM::Models.find(model)&.provider` alone (pre-#5014) | **5** — `ProviderCredentialsTest#resolves_a_model_this_host's_registry_does_not_hold`, `#a_partial_registry_does_not_turn_an_uncredentialed_host_into_a_configured_one`, `#a_partial_registry_does_not_hide_a_missing_key_for_another_provider`, `ChatResolverTest#the_degrade_still_fires_when_the_host's_registry_is_partial`, `ScopeIsolationTest#a_partial_registry_does_not_switch_the_degrade_off_under_any_cell` |

3 failures + 2 errors (the two that reach `create_conversation` raise `ModelNotFoundError` out
of a `before_save` rather than failing an assertion — which is the defect's actual shape). No
pre-existing test changed colour in either direction.

## Screenshots — a genuinely running `test/dummy`

`bin/rails db:prepare && bin/rails db:seed`, `bin/rails server -p 3141` from **this worktree**
with `ANTHROPIC_API_KEY` unset (`lsof` confirmed the Puma on 3141 had this worktree's
`test/dummy` as its cwd and was writing this worktree's `log/development.log`). Signed in as
Dana at Acme Corp, opened Kit, asked the same question in both runs.

Two temporary edits put the demo into the production condition, and both are reverted — the
committed tree has neither:

- **One row in `models`** (`gpt-4.1-nano`/`openai`), because a fresh demo has **zero** — which
  is exactly why this never showed up in the demo. A real host gets that row from having talked
  to a model; offline there is no way to earn one, so it was inserted directly. The row's
  contents are irrelevant: what matters is that a non-empty table flips RubyLLM to the
  ActiveRecord source, which the log shows (`SELECT "models".*` on every turn).
- **`c.default_provider = nil`** in `test/dummy/lib/dummy/concierge_setup.rb`. It is documented
  and supported ("leave nil to let RubyLLM resolve the model normally"), and it is what puts the
  whole gate on the model lookup — a host that names its provider is asked about that provider
  directly and never reaches this.

| Screenshot | What it shows |
|---|---|
| `before-degrade-switched-off.png` | Kit answers Dana with **"Could not reach the assistant."** Server-side: `Completed 500`, `RubyLLM::ModelNotFoundError (Unknown model: "claude-sonnet-4-5")` raised out of `acts_as_chat`'s `before_save` — an offline host, on the offline path, with a scripted chat waiting that it never reached. |
| `after-degrade-restored.png` | The same question, same server, same partial registry: Kit gives the scripted offline reply. The log shows the gate firing instead — `[concierge] no credentials configured for "claude-sonnet-4-5"; running without a persisted conversation`. `Concierge::Conversation.count == 0` and the `AgentRun` has `chat_id: nil`, so the degrade is the documented one, not a quiet success. |

## What could not be verified

- **No live model.** `ANTHROPIC_API_KEY` was unset for both runs, so the dummy used its
  scripted chat (`Dummy::ScriptedChat`). That is the path under test — the whole point is what
  happens when there is no key — but it means nothing here drove a real provider, and the
  "credentials present" side of `configured?` is covered only by the suite's config-level
  assertions.
- **The `models` row was inserted, not earned.** A real host's table is populated by
  `acts_as_chat`/`Model.refresh!` talking to a provider. Offline that is impossible, so the
  condition was staged. What the fix turns on is only whether the table is empty, and the log
  confirms RubyLLM took the ActiveRecord source.
- **One registry file.** The `bundled_registry` memo re-reads when
  `RubyLLM.config.model_registry_file` changes; no test or run here repointed it, so that branch
  is reasoned about rather than exercised.
- **Not tested against ruby_llm > 1.16.0.** The source-selection behaviour this fix compensates
  for is read out of 1.16.0's `models.rb`. The gemspec allows `< 2.0`, so a 1.17 that changed
  `load_models` could change the shape of the problem.

## Filed, not fixed

One defect found while reproducing this, out of scope and filed as its own ty task in
`concierge`: **a credentialed host with a stale `models` table and no `default_provider` still
raises `ModelNotFoundError` out of `create_conversation`.** Same root cause (a partial
registry), different failure: it is a loud, accurate error whose text names the fix
(`Model.refresh!`), not a silently disabled degrade. Fixing it would mean `ChatResolver#pin_model`
setting `assume_model_exists` from a provider it resolved itself, which contradicts the
documented meaning of leaving `default_provider` nil — a deliberate decision, not a one-liner.

**Fixed since, as task 5018 — but not where this predicted.** Task 5017 rewrote `pin_model` to
assign the model *record* rather than a string, so `create_conversation` stopped raising on its
own. The raise moved one step later, into the default chat factory's `to_llm`, and the decision
this section framed never had to be taken: `default_provider` still means what
`configuration.rb` says it means. See `docs/design/qa/5018-stale-registry-turn/README.md`.
