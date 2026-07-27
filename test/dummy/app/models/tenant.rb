class Tenant < ApplicationRecord
  PLANS = %w[free pro enterprise].freeze

  has_many :users, dependent: :destroy
  has_many :changelog_entries, dependent: :destroy
  has_many :inbox_messages, dependent: :destroy

  def card_on_file? = card_last4.present?

  # Bill's whole reason for writing. Kept on the host's own record rather than
  # anywhere in the engine: the engine reaches it, if it ever needs to, through a
  # declared account attribute — never by looking a tenant up by a raw id.
  def card_expiring?(within: 90.days)
    card_expires_on.present? && card_expires_on <= Date.current + within
  end
end
