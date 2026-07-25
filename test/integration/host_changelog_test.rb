require "test_helper"

# The product. It matters that this is real: the CSM's charter is "get each
# account to publish their first changelog", and an agent advising you to do
# something you cannot do is a demo of nothing.
class HostChangelogTest < ActionDispatch::IntegrationTest
  include Concierge::Test::HostApp

  setup { sign_in_as @dana }

  test "an account with nothing published is told so" do
    get changelog_entries_path

    assert_response :success
    assert_select ".empty h2", text: "Nothing here yet"
  end

  test "writing a draft and publishing it" do
    post changelog_entries_path,
         params: { changelog_entry: { title: "Scheduled exports", body: "Nightly CSVs." } }
    assert_redirected_to changelog_entries_path

    entry = @acme.changelog_entries.sole
    assert_equal "draft", entry.status
    assert_equal @dana, entry.author
    assert_nil entry.published_at

    post publish_changelog_entry_path(entry)
    assert_redirected_to changelog_entries_path

    entry.reload
    assert_equal "published", entry.status
    assert entry.published_at
  end

  test "a blank title does not save" do
    post changelog_entries_path, params: { changelog_entry: { title: "", body: "x" } }

    assert_response :unprocessable_entity
    assert_equal 0, @acme.changelog_entries.count
  end

  test "publishing changes what the agent's snapshot says about the account" do
    scope = csm_scope(@acme)
    assert_equal 0, Concierge::Snapshot.for(scope.subject, playbook: scope.agent.playbook)
                                       .to_h[:published_changelogs]

    entry = @acme.changelog_entries.create!(title: "Webhooks v2")
    post publish_changelog_entry_path(entry)

    assert_equal 1, Concierge::Snapshot.for(scope.subject, playbook: scope.agent.playbook)
                                       .to_h[:published_changelogs]
  end

  test "another account's entry is not reachable by id" do
    theirs = @globex.changelog_entries.create!(title: "Globex only")

    get edit_changelog_entry_path(theirs)
    assert_response :not_found

    post publish_changelog_entry_path(theirs)
    assert_response :not_found

    assert_equal "draft", theirs.reload.status
  end
end
