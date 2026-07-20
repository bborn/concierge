# Concierge configuration for the dummy host app.
#
# This mirrors test/support/dummy_config.rb (the canonical example config) but
# also runs under `bin/rails server`, so the engine's admin surface and chat
# endpoint can be exercised by hand. See db/seeds.rb for sample data.

Rails.application.config.to_prepare do
  Concierge.configure do |c|
    c.default_model = "claude-sonnet-4-5"

    # Without an API key there is nothing to talk to, so fall back to a scripted
    # reply. This keeps the dummy app usable offline; set ANTHROPIC_API_KEY to
    # drive a real model instead.
    unless ENV["ANTHROPIC_API_KEY"]
      c.chat_factory = ->(model:, chat_record: nil) { Dummy::ScriptedChat.new }
    end

    c.account do
      subject_class Tenant
      grain :account
      attribute(:name) { |t| t.name }
      attribute(:plan) { |t| t.plan }
      scope(:users)    { |t| t.users }
    end

    c.playbook do
      product_brief "Acme helps teams publish changelogs."
      goals "Get each account to publish their first changelog and upgrade."
      account_types :brand, :creator

      engagement_signal(:has_paid_plan) { |s| %w[pro enterprise].include?(s[:plan]) }
      engagement_signal(:user_count)    { |s| s.scope_for(:users).count }
      engagement_signal(:days_since_active) do |s|
        last = s.to_model.last_active_at
        last ? ((Time.current - last) / 1.day).floor : nil
      end

      persona name: "Kit", voice: "warm, concise, never pushy"
    end

    c.capabilities do
      register Concierge::Tools::RecallTool,                access: :read
      register Concierge::Tools::RememberTool,              access: :write
      register Concierge::Tools::ForgetTool,                access: :write
      register Concierge::Tools::SetOutreachPreferenceTool, access: :write
      register Concierge::Tools::RoutineTool,               access: :write
    end

    c.channels          = [ Concierge::Channel::InApp, Concierge::Channel::Email ]
    c.email_address_for = ->(subject) { subject.to_model.users.first&.email }
    c.mailer_host       = "localhost:3000"

    # The admin fails closed without this hook. The dummy app has no real auth,
    # so allow it in development only — a host app would check its own session.
    c.authenticate_admin = ->(_controller) { Rails.env.development? }

    c.weekly_review_enabled     = true
    c.weekly_review_instruction = "Review this account and reach out if something is worth their attention."
    c.priority = ->(subject) { subject[:plan] == "enterprise" ? 100 : 1 }
  end
end

module Dummy
  # Offline stand-in for a RubyLLM chat, mirroring the fluent surface
  # Concierge::Run drives. Unlike the test FakeChat this isn't scripted per
  # call — it just answers, so the dummy app works without an API key.
  class ScriptedChat
    Reply = Struct.new(:content, :tool_calls, :input_tokens, :output_tokens, keyword_init: true)

    def with_instructions(_text, replace: false) = self
    def with_temperature(_value) = self
    def with_context(_context)   = self
    def with_params(**)          = self
    def with_tools(*)            = self

    def ask(_prompt)
      reply = Reply.new(
        content: "Thanks for reaching out! I can see you're on the Pro plan and " \
                 "haven't published a changelog yet. Want me to walk you through it?",
        tool_calls: [], input_tokens: 320, output_tokens: 48
      )
      yield reply if block_given?
      reply
    end
  end
end
