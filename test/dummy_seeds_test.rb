require "test_helper"
require "open3"
require "json"
require "tmpdir"

module Concierge
  # What the demo host seeds is not just fixture data — a rule and a memory both
  # reach the model as prose, under a preamble that tells it they "override your
  # own judgement and the conventions you'd otherwise assume." So the seeds are
  # a worked example of what a human may legitimately put in force, and anyone
  # standing up their own agent will copy their shape.
  #
  # One thing they may not model: instructing the agent to hide that it is
  # automated. A live model was observed answering "yes — I'm an AI assistant"
  # to a seeded rule saying never to mention automation, and citing that rule
  # (§10.4, and `run_provenance_test.rb` keeps that contradiction as a fixture
  # on purpose). Disclosing was the better behaviour. The fix is the seed, not
  # the agent — hence this test, which asserts on the records `db:seed` actually
  # writes rather than on the source text of the file that writes them.
  #
  # Out of process, against a throwaway database, for the same reason
  # `offline_boot_test.rb` is: seeds open with `delete_all` across every table,
  # so running them in-process would contend with the suite's own SQLite file.
  class DummySeedsTest < ActiveSupport::TestCase
    # Suppression of the agent's own nature, which is the thing being ruled out.
    # Deliberately narrow: each pattern needs a *silencing* verb aimed at *what
    # the agent is*. "Never promise a delivery date" and "Never auto-charge this
    # account" are fine instructions and must keep passing.
    CONCEALMENT = {
      "silences a disclosure" =>
        /\b(never|don'?t|do not|avoid)\b[^.;]{0,40}\b(mention|say|admit|reveal|disclose|acknowledge|bring up)\b[^.;]{0,40}\b(ai|a\.i\.|bot|robot|automation|automated|machine|model|assistant)\b/i,
      "asks it to pass as human" =>
        /\b(pretend|pose|pass|present yourself)\b[^.;]{0,20}\b(as|to be)\b[^.;]{0,20}\b(a )?(human|person|real)\b/i,
      "asks it to conceal or hide something about itself" =>
        /\b(conceal|hide|deny)\b[^.;]{0,40}\b(you'?re|you are|being|that it is|it is|its nature|automation|automated|ai|bot)\b/i
    }.freeze

    SCRIPT = <<~RUBY.freeze
      load Rails.root.join("db/seeds.rb").to_s

      print "SEEDED_JSON:" + {
        rules:    Concierge::AgentRule.pluck(:state, :body),
        memories: Concierge::Memory.pluck(:source, :body)
      }.to_json
    RUBY

    test "no seeded rule or memory instructs the agent to conceal that it is automated" do
      seeded = run_seeds

      instructions = seeded["rules"].map { |state, body| [ "#{state} rule", body ] } +
                     seeded["memories"].map { |source, body| [ "#{source} memory", body ] }

      assert_operator instructions.length, :>, 10,
        "seeds wrote almost nothing; the assertion below would pass vacuously"

      CONCEALMENT.each do |description, pattern|
        offenders = instructions.select { |_kind, body| body.match?(pattern) }

        assert_empty offenders.map { |kind, body| "#{kind}: #{body}" },
          "a seeded instruction #{description}. The demo must not model that: " \
          "when a customer asks whether they are talking to a bot, disclosing " \
          "is the right answer. Reword the seed, do not teach concealment."
      end
    end

    # The half of that rule that was worth keeping. Deleting the rule outright
    # would satisfy the test above and quietly drop the example of an
    # account-specific tone instruction, which is the reason it is seeded.
    test "the account-specific tone rule survives as a tone rule" do
      bodies = run_seeds["rules"].map(&:last)

      tone = bodies.select { |body| body.match?(/low-key/i) }

      refute_empty tone, "the seeded low-key tone instruction is gone entirely"
      assert tone.any? { |body| body.match?(/skeptical of AI tooling/i) },
        "the account-specific tone rule no longer explains why it is low-key"
    end

    # Seeds run against a database of their own, with the credentials cleared:
    # that is the path the README documents (`bin/rails db:seed` offline), and
    # it keeps this out of the suite's SQLite file. Two boots is one too many,
    # so both tests read the same inventory.
    def self.seeded
      @seeded ||= Dir.mktmpdir("concierge-seeds") do |dir|
        dummy = File.expand_path("dummy", __dir__)
        env   = {
          "ANTHROPIC_API_KEY" => nil, "OPENAI_API_KEY" => nil, "RAILS_ENV" => "test",
          "DATABASE_URL" => "sqlite3:#{File.join(dir, 'seeds.sqlite3')}"
        }

        _out, prep_err, prep_status = Open3.capture3(env, "bin/rails", "db:prepare", chdir: dummy)
        raise "could not prepare the seed database:\n#{prep_err}" unless prep_status.success?

        out, err, status = Open3.capture3(env, "bin/rails", "runner", SCRIPT, chdir: dummy)
        raise "bin/rails db:seed failed:\n#{err}" unless status.success?

        payload = out[/SEEDED_JSON:(.*)\z/m, 1]
        raise "the seed run printed no inventory:\n#{out}\n#{err}" unless payload

        JSON.parse(payload)
      end
    end

    private
      def run_seeds = self.class.seeded
  end
end
