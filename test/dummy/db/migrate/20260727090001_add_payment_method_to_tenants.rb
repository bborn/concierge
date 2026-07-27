# The card on file, so "Update payment method" lands somewhere that actually
# changes something. Bill's outreach is about a card that expires in March; a
# button off that message that opens a page with no card on it would be a demo
# of a button, not of the seam.
class AddPaymentMethodToTenants < ActiveRecord::Migration[7.1]
  def change
    add_column :tenants, :card_last4,      :string
    add_column :tenants, :card_expires_on, :date
  end
end
