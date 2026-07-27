# QA — a stale host registry must not fail the turn (task 5018)

A credentialed host with a stale `models` table and no `default_provider` had its turn end in
`RubyLLM::ModelNotFoundError` **escaping `Concierge::Run` entirely** — not a failed `Result`, a
raise into the host's controller or job. No `AgentRun` row was written, so the audit trail had a
gap exactly where a turn was attempted.

All three conditions are ordinary:

1. the host has credentials (so the task-14 uncredentialed gate correctly does not fire);
2. `Concierge.config.default_provider` is nil — documented and supported, "leave nil to let
   RubyLLM resolve the model normally" (`lib/concierge/configuration.rb`);
3. the host's `models` table is non-empty but does not hold `default_model` — the normal state of
   any Rails host on `acts_as_model`, whose table only ever holds the models it has already
   talked to. Change `default_model` to something newer, or set a per-agent `Agent#model`, and
   the table has never heard of it.

## The report was right about the failure and wrong about the place

As filed, the raise came out of `acts_as_chat`'s `before_save` inside
`ChatResolver#create_conversation`, and the proposed remedy was for `pin_model` to set
`assume_model_exists` from a provider Concierge had inferred — which would have contradicted the
documented meaning of a nil `default_provider`.

Task 5017 landed in between and rewrote `pin_model` to assign the model **record** rather than a
string, which skips `resolve_model_from_strings` altogether. So `create_conversation` no longer
raises, and the decision the report framed never had to be taken. The raise had moved one step
later, and the reproduction on this branch's base shows exactly where.

## Reproduced first, on this branch's base

```
cd test/dummy && bin/rails db:prepare && bin/rails db:seed
ANTHROPIC_API_KEY=sk-ant-fake-for-repro bin/rails runner '
  Concierge.config.default_provider = nil
  Model.create!(model_id: "gpt-4.1-nano", name: "x", provider: "openai")
  RubyLLM::Models.instance_variable_set(:@instance, nil)   # drop the memo

  scope = Concierge::Scope.new(Concierge.config.agent(:csm),
            Concierge.config.account.find_subject(Tenant.find_by!(name: "Acme Corp").id))

  puts "registry holds: #{RubyLLM::Models.all.map(&:id).inspect}"
  puts "credentials configured?: #{Concierge::ProviderCredentials.configured?(model: "claude-sonnet-4-5")}"
  chat = Concierge::ChatResolver.call(scope)
  puts "ChatResolver: ok, chat=#{chat.id} model=#{chat.model_id} provider=#{chat.provider}"

  before = Concierge::AgentRun.count
  begin
    r = Concierge::Run.reactive(scope, "How do I publish my first changelog?")
    puts "Run: returned a Result — ok=#{r.ok?} error=#{r.error&.class}"
  rescue => e
    puts "Run RAISED (escaped Concierge::Run): #{e.class}"
  end
  puts "AgentRun rows: #{before} -> #{Concierge::AgentRun.count}"'
```

```
registry holds: ["gpt-4.1-nano"]
credentials configured?: true
ChatResolver: ok, chat=3 model=claude-sonnet-4-5 provider=anthropic
Run RAISED (escaped Concierge::Run): RubyLLM::ModelNotFoundError
AgentRun rows: 9 -> 9
```

`ProviderCredentials` answers correctly and `ChatResolver` resolves correctly — this is not a
credentials problem and no longer a persistence one. The turn is what breaks, and it breaks by
raising rather than failing.

## Why it broke there

`Configuration::DEFAULT_CHAT_FACTORY` resumes the conversation with `chat_record.to_llm`, and
`to_llm` (ruby_llm 1.16.0, `chat_methods.rb:80-87`) re-resolves the model:

```ruby
@chat ||= (context || RubyLLM).chat(
  model: model_record.model_id,
  provider: model_record.provider.to_sym,
  assume_model_exists: assume_model_exists || false
)
```

With a provider named and nothing assumed, `Models.resolve` takes its non-assume branch straight
into `Models.find` against the **process-wide memoized** registry. On a Rails host that registry
is the `models` table, so the lookup raises for the very row it was just handed — and for the row
`ChatResolver` wrote moments earlier, because the memo predates the insert.

Two things then had to be true for it to reach the host:

- `RubyLLM::ModelNotFoundError` derives from `StandardError`, **not** from `RubyLLM::Error`. This
  is the same trap `ConfigurationError` laid in task 14, and `Run`'s rescue had been widened for
  that one but not this one.
- `Run` rescues around `ChatResolver.call` too, so the *other* raise site — a model neither
  registry has heard of, which `ChatResolver` raises deliberately — was escaping as well.

## The fix

Two changes, and neither touches what `default_provider` means:

1. **`Configuration::DEFAULT_CHAT_FACTORY` sets `assume_model_exists`.** Not a shrug — `to_llm`
   is re-asking a question the record it was handed already answers. The model id got there by
   being resolved against RubyLLM's complete bundled data and written into the host's own `models`
   table; re-deriving it from a partial in-memory snapshot can only make the answer worse. A model
   nobody has heard of is still caught, earlier and with a better error, by `ChatResolver`.
2. **`Run` rescues `RubyLLM::ModelNotFoundError`.** A genuinely unresolvable model is a run that
   failed, and `Run`'s one promise is that a failed run comes back as a `Result` with provenance,
   not as an exception the host has to have thought about.

Same script, same seed data, on the fix:

```
registry holds: ["gpt-4.1-nano"]
credentials configured?: true
ChatResolver: ok, chat=3 model=claude-sonnet-4-5 provider=anthropic
Run: returned a Result — ok=false error=RubyLLM::UnauthorizedError
AgentRun rows: 9 -> 10
```

The model resolved, the turn reached Anthropic, and the fake key came back rejected — a
`RubyLLM::Error`, so a failed `Result` with an `AgentRun` row, which is what a bad key is
supposed to look like. Model resolution is no longer in the way.

## Coverage

Every one of these fails on the base commit and passes on the fix.

| Test | What it pins |
| --- | --- |
| `run_test.rb` — "a stale host registry still completes a turn" | the filed defect, over the real `acts_as_chat`/`to_llm` path with only the HTTP POST stubbed |
| `run_test.rb` — "a model no registry knows is a failed Result, not a raise" | the second raise site, from `ChatResolver` inside `Run` |
| `run_test.rb` — "an unresolvable model records failed provenance" | the `AgentRun` row a raise used to skip |
| `chat_resolver_test.rb` — "a partial host registry resolves the same way with credentials present" | the existing partial-registry test clears the key; the filed repro had it set |
| `scope_isolation_test.rb` — "a partial registry leaves every cell's online turn its own" | the (agent × account) grid completes rather than raising mid-way, and each cell's chat, run and words stay its own |

The isolation test is the one the report asked for by name: a raise mid-grid leaves the cells
behind it with an `AgentRun` row apiece and the cells ahead of it with nothing, which is a
half-populated audit trail written by a path nobody chose.

## Limits

- **`assume_model_exists` only on the default factory.** A host that supplies its own
  `chat_factory` owns its own resolution semantics, by design, and is unaffected.
- **A retired model id now 404s at the provider** rather than failing locally. That is a
  `RubyLLM::Error`, so a failed `Result`, and the provider is the authority on what it still
  serves. An id that was never real is still caught locally by `ChatResolver`.
- **Not tested against ruby_llm > 1.16.0.** The `to_llm` re-resolution this compensates for is
  read out of 1.16.0's `chat_methods.rb`. The gemspec allows `< 2.0`.
- **`Model.refresh!` is still the host's cure for a stale table**, and RubyLLM's error still says
  so wherever it is raised. This change means a stale table costs the host nothing until it names
  a model that genuinely does not exist.
