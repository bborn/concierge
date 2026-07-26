module Concierge
  module Test
    # A queue that will not take work.
    #
    # Slack::Intake#hand_off_execution has a branch for exactly this — the enqueue
    # raises, the decision stays durable, and the operator is told the approval is
    # recorded and waiting in the admin queue. Nothing exercised it, and it is the
    # branch that must *not* leave "queued to be performed" on the row: no job
    # exists, so nothing would ever clear it.
    #
    # A real adapter rather than a stubbed +perform_later+, so the test drives the
    # same call the production path does and cannot pass by mocking away the thing
    # it is checking.
    module BrokenQueue
      class Adapter
        Down = Class.new(StandardError)

        def enqueue(_job)    = raise Down, "the queue is down"
        def enqueue_at(*)    = raise Down, "the queue is down"
      end

      # Per job class, not globally: the point is one enqueue failing, with every
      # other queue in the test still behaving.
      def with_broken_queue(job_class = Concierge::ProposalExecutionJob)
        original = job_class.queue_adapter
        job_class.queue_adapter = Adapter.new
        yield
      ensure
        job_class.queue_adapter = original
      end
    end
  end
end
