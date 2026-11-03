require "test_helper"

module Concierge
  # Token accounting against ruby_llm 2.x's real reply shape.
  #
  # ruby_llm 2.x moved usage off the message's +input_tokens+/+output_tokens+
  # readers onto one +RubyLLM::Tokens+ value at +Message#tokens+. Run used to read
  # the old names through +respond_to?+, which does not raise on a 2.x message —
  # it is simply false — so every run recorded nil tokens and Budget#spend!
  # charged nothing, with the whole suite green, because every double here faked
  # the 1.x shape. These tests hand Run a *real* +RubyLLM::Message+, so the shape
  # under test is the one the gem actually returns.
  class RunTokenAccountingTest < ActiveSupport::TestCase
    # Returns a real RubyLLM::Message from +ask+ — nothing else about the chat
    # matters to token accounting.
    class RealMessageChat
      def initialize(message) = @message = message
      def with_instructions(*, **) = self
      def with_tools(*) = self
      def ask(*, **) = @message
    end

    setup do
      @tenant  = Tenant.create!(name: "Acme", plan: "pro", last_active_at: 1.day.ago)
      @tenant.users.create!(email: "a@acme.test")
      @subject = Concierge.config.account.build(@tenant)
      @scope   = Concierge::Scope.new(Concierge.config.agent(:csm), @subject)
    end

    test "a real RubyLLM::Message's tokens reach the Result and the run record" do
      script_real_message(input: 321, output: 45)

      result = Concierge::Run.reactive(@scope, "how am I doing?")

      assert result.ok?
      assert_equal 321, result.input_tokens
      assert_equal 45, result.output_tokens
      assert_equal 366, result.total_tokens

      run = Concierge::AgentRun.order(:id).last
      assert_equal [ 321, 45 ], [ run.input_tokens, run.output_tokens ]
    end

    test "a proactive review spends the real message's tokens against the budget" do
      Concierge.config.budget = { per_tenant: 1_000_000, global: 1_000_000 }
      script_real_message(input: 321, output: 45)

      Concierge::AccountReviewJob.perform_now(@tenant.id, instruction: "weekly review", channel: :in_app)

      assert_equal 366, Concierge::Budget.new.spent_for(@subject)
    end

    # The same thing end to end: the real Anthropic parser builds the message from
    # the provider's own usage block, over the real acts_as_chat path.
    test "the provider's reported usage is recorded on the real chat path" do
      Concierge.config.chat_factory = persisting_chat_factory

      result = with_model_reply("Hello.", input_tokens: 12, output_tokens: 7) do
        Concierge::Run.reactive(@scope, "hi")
      end

      assert result.ok?, -> { result.error.inspect }
      assert_equal [ 12, 7 ], [ result.input_tokens, result.output_tokens ]
      run = Concierge::AgentRun.order(:id).last
      assert_equal [ 12, 7 ], [ run.input_tokens, run.output_tokens ]
    end

    private

    def script_real_message(input:, output:)
      message = RubyLLM::Message.new(
        role: :assistant, content: "All good.",
        tokens: RubyLLM::Tokens.new(input: input, output: output)
      )
      Concierge.config.chat_factory = ->(model:, chat_record: nil) { RealMessageChat.new(message) }
    end
  end
end
