# The product. Acme helps teams publish changelogs, which is what the :csm
# playbook says the agent is trying to get each account to do — so the thing the
# agent advises about is a thing the signed-in user can actually go and do.
class ChangelogEntry < ApplicationRecord
  STATUSES = %w[draft published].freeze

  belongs_to :tenant
  belongs_to :author, class_name: "User", optional: true

  validates :title,  presence: true
  validates :status, inclusion: { in: STATUSES }

  scope :published,    -> { where(status: "published") }
  scope :drafts,       -> { where(status: "draft") }
  scope :newest_first, -> { order(Arel.sql("COALESCE(published_at, updated_at) DESC"), id: :desc) }

  def published? = status == "published"
  def draft?     = status == "draft"

  def publish!
    update!(status: "published", published_at: Time.current)
  end

  def unpublish!
    update!(status: "draft", published_at: nil)
  end
end
