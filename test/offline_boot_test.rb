require "test_helper"
require "open3"

module Concierge
  # The one test in this suite that does not run in this process.
  #
  # test_helper sets ANTHROPIC_API_KEY deliberately (it is the signal that a Chat
  # never resolves RubyLLM's *global* default provider), so no test in here can
  # ever observe a genuinely keyless boot — and that is precisely the state the
  # README documents and the state that was broken. PR #5 papered over it by
  # giving the dummy host a placeholder key, which would have kept every
  # in-process test green no matter what the engine did.
  #
  # So: boot the dummy host in a separate process with the variable actually
  # removed from the environment, and check what a keyless host needs — including
  # a whole turn, end to end, because "the engine persists a conversation without
  # credentials" is exactly the kind of claim that a suite with a key in its
  # environment can assert while being wrong.
  #
  # The turn runs against a throwaway in-memory database loaded from the dummy's
  # own schema, so the child neither needs a seeded database nor contends with the
  # suite's SQLite file.
  class OfflineBootTest < ActiveSupport::TestCase
    SCRIPT = <<~RUBY.freeze
      raise "ANTHROPIC_API_KEY leaked into the child process" if ENV["ANTHROPIC_API_KEY"]

      # 1. No initializer may invent a credential the environment did not give.
      #    A placeholder here is what hid this bug for a phase.
      raise "a placeholder anthropic key was installed at boot" if RubyLLM.config.anthropic_api_key

      # 2. The engine must *know* it is uncredentialed, rather than finding out
      #    from a raise inside a before_save.
      raise "provider reported as configured with no key" if
        Concierge::ProviderCredentials.configured?(provider: :anthropic)

      # 3. And the host must be configured for the offline path the README
      #    promises: a scripted chat, not a live one.
      raise "keyless host was left with the live chat factory" if
        Concierge.config.chat_factory == Concierge::Configuration::DEFAULT_CHAT_FACTORY

      # 4. Then the thing all of that is for. A genuinely keyless host runs a turn
      #    and is left with a conversation, both halves of it written down, and a
      #    provenance row pointing at each — the offline demo's transcript, on the
      #    only path that can prove it without a key in the environment.
      ActiveRecord::Base.establish_connection(adapter: "sqlite3", database: ":memory:")
      ActiveRecord::Schema.verbose = false
      load Rails.root.join("db/schema.rb").to_s

      tenant  = Tenant.create!(name: "Keyless", plan: "pro")
      subject = Concierge.config.account.find_subject(tenant.id)
      scope   = Concierge::Scope.new(Concierge.config.agent(:csm), subject)
      asked   = "how do I publish my first changelog?"
      result  = Concierge::Run.reactive(scope, asked)

      raise "the keyless run failed: \#{result.error.inspect}" unless result.ok?

      run = result.run_record
      raise "a keyless run recorded no host chat" unless run.chat_id
      raise "the customer's question was not persisted (\#{run.prompt_unavailable_reason})" unless
        run.prompt_text == asked
      raise "the reply was not persisted (\#{run.reply_unavailable_reason})" if run.reply_text.to_s.empty?
      raise "the conversation was not the one this scope owns" unless
        Concierge::Conversation.find_by_scope(scope)&.chat_id == run.chat_id

      print "OFFLINE_BOOT_OK"
    RUBY

    test "a keyless dummy host boots, reports itself offline, and keeps a transcript" do
      dummy = File.expand_path("dummy", __dir__)
      env   = { "ANTHROPIC_API_KEY" => nil, "OPENAI_API_KEY" => nil, "RAILS_ENV" => "test" }

      out, err, status = Open3.capture3(env, "bin/rails", "runner", SCRIPT, chdir: dummy)

      assert status.success?, "keyless boot failed:\n#{err}"
      assert_equal "OFFLINE_BOOT_OK", out.strip, "keyless boot reported:\n#{out}\n#{err}"
    end
  end
end
