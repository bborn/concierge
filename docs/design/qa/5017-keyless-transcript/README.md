# QA — a keyless demo that keeps a transcript (task 5017)

With `ANTHROPIC_API_KEY` unset, `Concierge::ChatResolver` declined to create the
host `Chat` at all, so a keyless host had **no `Conversation`, no chat rows and
no messages**. Every surface that reads the host's chat tables was therefore
permanently empty offline, and a change to what the engine persists could only be
demonstrated by reading seeded stand-ins.

## Reproduced first, on this branch's base

```
cd test/dummy
env -u ANTHROPIC_API_KEY bin/rails runner '
  acme    = Tenant.find_by!(name: "Acme Corp")
  subject = Concierge.config.account.find_subject(acme.id)
  scope   = Concierge::Scope.new(Concierge.config.agent(:csm), subject)
  before  = [Chat.count, Message.count, Concierge::Conversation.count]
  result  = Concierge::Run.reactive(scope, "How do I publish my first changelog?")
  after   = [Chat.count, Message.count, Concierge::Conversation.count]
  run     = Concierge::AgentRun.order(:id).last
  puts "ok=#{result.ok?}"
  puts "chats #{before[0]}->#{after[0]}  messages #{before[1]}->#{after[1]}  conversations #{before[2]}->#{after[2]}"
  puts "run chat_id=#{run.chat_id.inspect} message_id=#{run.message_id.inspect} prompt_message_id=#{run.prompt_message_id.inspect}"'
```

```
ok=true
chats 1->1  messages 4->4  conversations 0->0
run chat_id=nil message_id=nil prompt_message_id=nil
```

The turn answered; nothing about it was written down anywhere. (The 1 chat and 4
messages are the stand-ins `db/seeds.rb` inserts by hand.)

## The fix, and why the earlier finding was not the last word

Task 4997 established — correctly — that `Models.resolve` instantiates the
provider on **both** branches, so no combination of `assume_model_exists` /
`provider` gets a `Chat` record created without credentials. What it did not
check is the option this task's report guessed at: **don't hand `acts_as_chat` a
string at all.**

`ChatMethods#resolve_model_from_strings` (ruby_llm 1.16.0, chat_methods.rb:46-49)
returns immediately when `model_association` is already set and no string is
pending. Assigning the model **record** therefore skips the whole `before_save`,
and `Models.resolve` is never reached:

```
env -u ANTHROPIC_API_KEY bin/rails runner '
  info   = RubyLLM::Models.new(RubyLLM::Models.read_from_json(RubyLLM.config.model_registry_file))
                          .find("claude-sonnet-4-5", :anthropic)
  record = Model.find_or_create_by!(model_id: info.id, provider: info.provider) { |m| m.name = info.name }
  chat   = Chat.new; chat.model = record; chat.save!
  puts "chat #{chat.id} model=#{chat.model_id} provider=#{chat.provider}"'
#=> chat 3 model=claude-sonnet-4-5-20250929 provider=anthropic
```

So `ChatResolver` now resolves the model itself — a faithful port of
`Models.resolve` (models.rb:154-183) with the one line removed that builds the
provider — writes the host's `models` row, and assigns the association. Online and
offline become one path. The pinned model id is unchanged (`claude-sonnet-4-5`,
not the alias-resolved one) because a host that names its provider still takes
resolve's assume-exists branch, exactly as `pin_model` told RubyLLM to before.

The registry lookup that remains is the one a host with `default_provider: nil`
depends on, and it goes through the new `Concierge::ModelRegistry`, which falls
back to RubyLLM's bundled data when the host's own `models` table cannot answer —
the same lesson task 5014 fixed one layer up, now in one place both callers share.

The demo host's `Dummy::ScriptedChat` takes the `chat_record` it is handed and
writes both halves of the turn into it. That is the host's job: a host that
supplies its own `chat_factory` owns its own persistence semantics.

## After the fix — same command, no key anywhere

```
ok=true
chats 2->3  messages 5->7  conversations 0->1
run chat_id=4 message_id=11 prompt_message_id=10
```

## In the running dummy host, with `ANTHROPIC_API_KEY` genuinely unset

`cd test/dummy && env -u ANTHROPIC_API_KEY bin/rails db:reset && env -u ANTHROPIC_API_KEY bin/rails server`
— signed in as Dana at Acme, driven through a real browser.

| | |
|---|---|
| **`00-run-detail-before.png`** | The same screen, on this branch's base, after the same question through the same widget. *"No host chat was recorded for this run, so there is no question to read."* on one half and *"…so there is no message to read"* on the other. Every offline run read this way. |
| **`01-widget-keyless-turn.png`** | Kit answering "How do I publish my first changelog?" with no key — over the real assembled prompt (it knows Dana has 1 draft and is on `pro`). |
| **`02-run-detail-keyless.png`** | That turn at `/concierge/admin/runs/19`: **What the customer asked** and **What the agent actually said**, both read live out of the host's own chat tables (chat #3, message #10). This is the screen the whole task is about. |
| **`03-run-detail-proactive-keyless.png`** | "Kit, take a look" — the proactive path — as run #20, on the *same* chat #3. **What set the agent off** shows the instruction, and the reply is message #12. |

The database afterwards — one thread per (agent, account), both turns in it:

```
chat 3
  9 user: How do I publish my first changelog?
  10 assistant: Publishing takes about a minute: open Changelog, hit New entry, …
  11 user: Review this account and reach out if something is worth their attention.
  12 assistant: You haven't published a changelog entry yet, and that's the one …
run #20 proactive chat=3 q=11 a=12
run #19 reactive  chat=3 q=9  a=10
```

...and the warning, once, when the conversation is opened rather than on every
run as before:

```
[concierge] no credentials configured for anthropic; opening a persisted
conversation anyway, but no turn on it will reach a provider until the provider's
API key is set.
```

```
$ grep -c "no credentials configured" log/development.log
1                      # two widget turns, one conversation, one warning
```

## Tests

`make verify`: rubocop clean over 267 files, **658 runs / 2515 assertions / 0
failures / 0 errors** (was 649 runs on the base).

New / rewritten:

- **`test/offline_transcript_test.rb`** (new, 8 tests) — the counterpart to
  `online_transcript_test.rb`. Runs the demo host's own `ScriptedChat` factory
  rather than a double written for the tests.
- **`test/offline_boot_test.rb`** — the one test that runs in a *separate process
  with the variable actually removed*. It now runs a whole turn against a
  throwaway in-memory database and asserts the conversation, both message rows,
  and the provenance pointers. This is the only place the claim can be checked
  without the suite's own key covering for it.
- **`test/integration/host_chat_widget_test.rb`** — a keyless turn through the
  endpoint a browser posts to, with `ConciergeSetup` re-read so the *host's* offline
  wiring is what runs (`with_keyless_host`). This is the only test that covers the
  `chat_factory` line in the demo config.
- **`test/chat_resolver_test.rb`** — including one that asserts
  `RubyLLM::Models.resolve` is never reached, which a credentialed suite would
  otherwise let a regression hide.
- **`test/scope_isolation_test.rb`** — the load-bearing invariant, *extended
  rather than tested beside*. The offline path used to keep the grid apart by
  holding nothing; it now writes a second full set of host chats, so the same
  questions the online tests ask are asked of it: each cell its own chat, its own
  conversation, its own run pointer, and — with a persisting host factory — its
  own customer questions, replayed into its own next prompt and nobody else's.

### Mutation testing

| mutation | red |
|---|---|
| revert `lib/concierge/chat_resolver.rb` to its pre-fix form | **19** (12 failures + 7 errors), across `ChatResolverTest`, `OfflineTranscriptTest`, `OfflineBootTest`, `RunTest`, `RunReplyLinkTest`, `ScopeIsolationTest` |
| `Dummy::ScriptedChat#ask` stops writing the two rows | **6** |
| the dummy's `chat_factory` stops passing `chat_record:` | **2** (`OfflineBootTest`, `HostChatWidgetTest`) |

All reverted; suite green.

## What I could not verify

- **Nothing was tested against a real model.** `ANTHROPIC_API_KEY` was unset for
  every browser session above, on purpose — that is the path under test. The
  *credentialed* path was exercised only through `test/support/stubbed_provider.rb`
  (real `RubyLLM::Chat`, real `acts_as_chat` callbacks, real Anthropic response
  parsing, HTTP POST stubbed) and by the fact that the credentialed assertions in
  `chat_resolver_test.rb` are unchanged. No live provider call was made.
- **Only Anthropic's shape of provider was exercised.** `model_info` ports
  `Models.resolve`'s three branches — provider named, provider named *and* local
  (ollama-style), no provider named — but only the first and third are covered by
  tests, because the dummy declares `default_provider :anthropic` and the third is
  reached by setting it to `nil`. The `local?` branch is read from ruby_llm's
  source, not run.
- **Concurrency on the `models` row is argued, not observed.**
  `find_or_create_model` retries a `RecordNotUnique`/`RecordInvalid` by re-reading,
  but two processes racing to open the first conversation was not staged.
- **The widget's tool-call strip is still empty offline**, and that is now the
  honest answer rather than a limitation: the conversation exists and is readable,
  but a scripted stand-in calls no tools, so there are none to show. Seeing chips
  there still needs a real model.
- **`db/seeds.rb` still inserts its two contrasting turns by hand.** Not because
  it has to any more, but because those two replies differ in exactly the way the
  run screen exists to make visible, which no stand-in reproduces on demand. The
  comment saying it was forced to has been corrected.
