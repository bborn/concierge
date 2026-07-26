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
  # removed from the environment, and check the two things a keyless host needs.
  # It queries nothing, so it neither needs a seeded database nor contends with
  # the suite's own SQLite file.
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

      print "OFFLINE_BOOT_OK"
    RUBY

    test "the dummy host boots and reports itself offline with no API key set" do
      dummy = File.expand_path("dummy", __dir__)
      env   = { "ANTHROPIC_API_KEY" => nil, "OPENAI_API_KEY" => nil, "RAILS_ENV" => "test" }

      out, err, status = Open3.capture3(env, "bin/rails", "runner", SCRIPT, chdir: dummy)

      assert status.success?, "keyless boot failed:\n#{err}"
      assert_equal "OFFLINE_BOOT_OK", out.strip, "keyless boot reported:\n#{out}\n#{err}"
    end
  end
end
