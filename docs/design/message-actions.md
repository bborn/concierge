# Who decides what buttons a message carries

Status: decided, implemented.
Supersedes the question-mark heuristic in the demo host's `Inbox::Item#invites_reply?`.

## The seam

Task 5019 gave every in-app message a composer and a one-click affirmative, and
said out loud that a general "actions on a message" framework was out of scope.
The demo made the gap visible within a day:

* Kit's outreach ends in a question — *"Want me to help you get 'Scheduled
  exports' out the door?"* A composer and a **Yes, help me with that.** button
  are exactly right.
* Bill's outreach asks nothing — *"the card on file expires in March and there's
  no backup payment method on the account."* The useful response is not a
  sentence. It is a link to the payment settings.

The stopgap was a question-mark test on the body, which is crude in the way that
matters: it is the host pattern-matching prose it did not write, to guess at an
intent the author never encoded.

## Two answers that were both wrong on their own

**The agent emits the buttons.** Widen the outreach payload with an action
vocabulary the model writes. Fails because it makes the model responsible for
knowing what the host's product can do — and, worse, lets the model author the
label and the URL. A model that can write `href` writes customer-facing links
that nobody declared.

**The host infers them from `kind` / agent slug.** No engine change, but the
host is still guessing. `kind` is a governance category (frequency caps, quiet
hours), not a statement about the product; "every message from `:billing` gets an
update-payment button" is wrong the first time Bill writes about an invoice PDF.

## The decision: the host declares, the agent selects, the engine carries the key

Three parties, each doing only what it is actually authoritative about.

1. **The host declares a vocabulary**, per agent, in config. It owns its own
   product surface, so it owns the key, the caption, the URL, and the wording of
   when each one applies:

   ```ruby
   c.agent :billing do
     actions do
       offer :update_payment_method,
             label:    "Update payment method",
             use_when: "the card on file is expiring, missing, or has been declined",
             href:     "/account#payment"
     end
   end
   ```

2. **The engine advertises that vocabulary in the run's prompt**, next to the
   playbook rules. The agent is not asked to know what the host can do — it is
   *told*, in one line per action. `href` is never shown to the model; it has no
   use for it.

3. **The agent names keys**, on a trailing machine-readable line, exactly the way
   it already cites the rules it applied:

   ```
   Actions-Offered: update_payment_method
   Actions-Offered: none
   ```

   The line is stripped before anything reaches a customer, for the same reason
   `Rules-Applied:` is.

4. **The engine resolves those keys against what the host declared** and carries
   the resolved offers in the outreach payload. A key nobody declared is dropped
   and logged, the way a cited-but-uninjected rule id is recorded rather than
   trusted. **The model never authors a label, a URL, or an action** — it only
   picks from a list, and picking badly costs a missing button, not a fabricated
   one.

5. **The host renders them.** Whatever else an offer carries beyond `key` and
   `label` — `href`, canned `reply` text, a Turbo frame, a confirm string — is
   opaque to the engine. It is the host's own declaration handed back to it.

## What this buys, and what it costs

The payload contract widens by exactly one optional key, `actions`, whose values
originated in the host's own config. The host stops reading tea leaves. The model
gets a decision it is genuinely well-placed to make — *is this the moment for that
button* — and none of the decisions it is not.

The cost is honest and worth naming: a host with a live model now has a second
thing to get right in its config, and an agent that names nothing gets no
buttons. A message delivered with no run behind it (a seed, a `dispatch` call
from host code) carries whatever actions the caller passed and no more — which is
why the demo seeds name them explicitly. Silence is not a claim here either.

## The question mark is gone

The affirmative was never special. It is an offer whose payload is canned reply
text rather than a link, so the demo host declares it in the same vocabulary:

```ruby
c.agent :csm do
  actions do
    offer :yes_please,
          label:    "Yes, help me with that.",
          use_when: "you have offered to do something and the customer need only say yes",
          reply:    "Yes, help me with that."
  end
end
```

Kit's message carries it because Kit asked for a hand, not because the body ends
in `?`. Bill's carries **Update payment method** because Bill's product surface
has one and Bill judged it apt. The composer stays on every unanswered message:
a customer can always answer in words, and that was never the thing in question.

## Not decided here

* **Email.** `Channel::Email` does not render actions yet. It can — the payload
  carries a label and an href, which is what a button in an email needs — and
  that is precisely the second host surface this decision was made ahead of.
* **Provenance.** Offered keys are not written to `Concierge::AgentRun`. They are
  in the delivery payload and reachable from the host's own row; a dedicated
  audit column can wait until something needs to query them.
* **A cap on how many offers one message may carry.** The vocabularies are small
  and the host controls them. If that stops being true, cap it in `Actions`.
