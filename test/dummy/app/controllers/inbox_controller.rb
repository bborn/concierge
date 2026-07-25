# What the agent sent *you*. Proactive outreach that only ever showed up in the
# engine admin is outreach the customer never saw.
class InboxController < ApplicationController
  def index
    @items = inbox.items
  end

  def read
    current_tenant.inbox_messages.find(params[:id]).mark_read!
    redirect_to inbox_path
  end

  def read_all
    current_tenant.inbox_messages.unread.find_each(&:mark_read!)
    redirect_to inbox_path, notice: "Inbox cleared."
  end
end
