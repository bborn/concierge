# The product. Real records, real forms — the CSM's charter is "get each account
# to publish their first changelog", so the thing the agent advises about has to
# be a thing you can go and do.
class ChangelogEntriesController < ApplicationController
  before_action :set_entry, only: %i[edit update publish unpublish destroy]

  def index
    @entries   = current_tenant.changelog_entries.newest_first
    @published = @entries.count(&:published?)
  end

  def new
    @entry = current_tenant.changelog_entries.new
  end

  def create
    @entry = current_tenant.changelog_entries.new(entry_params)
    @entry.author = current_user

    if @entry.save
      redirect_to changelog_entries_path, notice: "Draft saved."
    else
      render :new, status: :unprocessable_entity
    end
  end

  def edit; end

  def update
    if @entry.update(entry_params)
      redirect_to changelog_entries_path, notice: "Changes saved."
    else
      render :edit, status: :unprocessable_entity
    end
  end

  def publish
    @entry.publish!
    redirect_to changelog_entries_path, notice: "Published “#{@entry.title}”."
  end

  def unpublish
    @entry.unpublish!
    redirect_to changelog_entries_path, notice: "“#{@entry.title}” is back to a draft."
  end

  def destroy
    @entry.destroy!
    redirect_to changelog_entries_path, notice: "Entry deleted."
  end

  private

  # Scoped through the tenant, so another account's entry id is a 404 rather than
  # somebody else's changelog.
  def set_entry
    @entry = current_tenant.changelog_entries.find(params[:id])
  end

  def entry_params
    params.require(:changelog_entry).permit(:title, :body)
  end
end
