class Tenant < ApplicationRecord
  has_many :users, dependent: :destroy
end
