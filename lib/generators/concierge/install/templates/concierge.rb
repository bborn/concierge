# Concierge configuration. Tell the gem what an account is, what your app does,
# what the agent may touch, and how it may reach the customer.
Concierge.configure do |config|
  config.default_model = "claude-sonnet-4-5"

  # 1. What is an account? Map your host model to Concierge's Subject.
  config.account do
    subject_class Account        # your team/tenant/workspace model
    grain :account               # :account (default) or :user
    attribute(:name) { |a| a.name }
    attribute(:plan) { |a| a.plan }
    # scope(:reports) { |a| a.reports }   # account-scoped relations tools may read
  end

  # 2. What does the app do, and what does "engaged" mean?
  config.playbook do
    product_brief "Describe your product in a sentence or two."
    goals "What does success look like for an account?"
    engagement_signal(:has_paid_plan) { |s| s[:plan] != "free" }
    # engagement_signal(:reports_created) { |s| s.scope_for(:reports).count }
    persona name: "Your Agent's Name", voice: "warm, concise, never pushy"
  end

  # 3. What may the agent touch? Register tools with least-privilege grants.
  config.capabilities do
    register Concierge::Tools::RecallTool,                access: :read
    register Concierge::Tools::RememberTool,              access: :write
    register Concierge::Tools::ForgetTool,                access: :write
    register Concierge::Tools::SetOutreachPreferenceTool, access: :write
    register Concierge::Tools::RoutineTool,               access: :write
  end

  # 4. How may it reach the customer?
  config.channels          = [ Concierge::Channel::InApp, Concierge::Channel::Email ]
  config.email_address_for = ->(subject) { subject.to_model.owner_email }
  config.mailer_host       = "your-app.example.com"

  # 5. Proactivity + cost governance (optional).
  config.weekly_review_enabled     = true
  config.weekly_review_instruction = "Review this account and reach out if something is worth their attention."
  config.budget = { per_tenant: 200_000, global: 5_000_000 } # daily token caps

  # 6. Autonomy. Concierge is autonomous within caps by default. Flip this on to
  # route every send to an outbox for human approval instead.
  # config.draft_and_review = true

  # 7. Guard the admin surface. Return truthy to allow.
  # config.authenticate_admin = ->(controller) { controller.current_user&.admin? }
end
