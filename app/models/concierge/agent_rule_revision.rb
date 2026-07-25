module Concierge
  # One immutable entry in a rule's paper trail: the exact instruction text, its
  # state, and its enforcement at a point in its life, plus who moved it.
  #
  # This is what makes a pinned provenance snapshot worth anything (§10.4). A run
  # records +{id:, version:}+; if the rule is later edited, the version that was
  # actually in the prompt is still here, verbatim. Without the trail, "rule 12
  # v2" is a citation of text nobody can produce any more.
  #
  # Deliberately not AgentScoped: a revision has no scope of its own. It belongs
  # to exactly one rule, and the rule carries the (agent, subject) keys — giving
  # the revision its own copy would be a second source of truth that could drift.
  class AgentRuleRevision < ApplicationRecord
    serialize :predicate, coder: JSON, type: Hash

    belongs_to :agent_rule, class_name: "Concierge::AgentRule",
               inverse_of: :revisions

    # Append-only. A trail you can edit is not a trail.
    def readonly?
      persisted?
    end
  end
end
