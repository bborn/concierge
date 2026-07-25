class Tenant < ApplicationRecord
  PLANS = %w[free pro enterprise].freeze

  has_many :users, dependent: :destroy
  has_many :changelog_entries, dependent: :destroy
  has_many :inbox_messages, dependent: :destroy
end
