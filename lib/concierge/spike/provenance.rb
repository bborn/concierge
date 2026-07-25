module Concierge
  module Spike
    # SPIKE (phase-10 step 0, §10.4). Throwaway — see lib/concierge/spike.rb.
    #
    # "Prove which policy was in force when the agent said what it said." Records,
    # per run, exactly what went into the prompt.
    #
    # In-memory only: §10.4's +concierge_agent_runs+ table is step 1's work and
    # this step migrates nothing. The shape of a Record is the shape that table
    # should take — +agent_slug+ first, because that is the dimension being added.
    module Provenance
      Record = Struct.new(
        :agent_slug, :subject_type, :subject_id,
        :memory_ids, :rule_ids, :snapshot_digest,
        :model, :input_tokens, :output_tokens, :trigger, :recorded_at,
        keyword_init: true
      ) do
        def subject_label
          "#{subject_type}##{subject_id}"
        end

        def total_tokens
          (input_tokens || 0) + (output_tokens || 0)
        end
      end

      LIMIT = 200

      class << self
        # Write one provenance row for a completed run.
        def record(scope:, memory_ids:, snapshot_digest:, model:, trigger:,
                   input_tokens: nil, output_tokens: nil, rule_ids: [])
          row = Record.new(
            agent_slug:      scope.agent_slug,
            subject_type:    scope.subject.grain.to_s,
            subject_id:      scope.subject.id.to_s,
            memory_ids:      Array(memory_ids),
            rule_ids:        Array(rule_ids),
            snapshot_digest: snapshot_digest,
            model:           model,
            input_tokens:    input_tokens,
            output_tokens:   output_tokens,
            trigger:         trigger.to_s,
            recorded_at:     Time.current
          )
          mutex.synchronize do
            records.unshift(row)
            records.pop while records.size > LIMIT
          end
          row
        end

        def recent(limit: 50)
          mutex.synchronize { records.first(limit) }
        end

        def for_agent(slug)
          recent(limit: LIMIT).select { |r| r.agent_slug == slug.to_s }
        end

        def reset!
          mutex.synchronize { @records = [] }
        end

        private

        def records
          @records ||= []
        end

        def mutex
          @mutex ||= Mutex.new
        end
      end
    end
  end
end
