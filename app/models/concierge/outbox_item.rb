module Concierge
  # Deprecated alias kept for one release (design §10.9). +concierge_outbox_items+
  # became +concierge_agent_proposals+ and the model generalized from "a drafted
  # message" to "an action an agent proposed but may not perform"
  # (Concierge::AgentProposal).
  #
  # This is a *read* bridge: a host's existing `OutboxItem.pending.for_scope(…)`
  # keeps answering, and `#body` / `#channel` / `#kind` still read through to the
  # payload. Writes should go through Concierge::Proposal — the old
  # `state: "pending"` and a bare `body:` column no longer exist, because the
  # table now stages arbitrary action classes and the arguments live in `payload`.
  OutboxItem = AgentProposal
end
