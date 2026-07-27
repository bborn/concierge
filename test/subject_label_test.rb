require "test_helper"

module Concierge
  # config.subject_label — what a subject is *called*, for the human reading the
  # queue. A caption, with a caption's obligations: it may not fail the page, and
  # it may never become an identifier.
  class SubjectLabelTest < ActiveSupport::TestCase
    setup do
      @tenant = Tenant.create!(name: "Crossroads Commons", plan: "pro")
      @row    = Concierge::Memory.create!(subject_type: "account", subject_id: @tenant.id.to_s,
                                          body: "note", source: "agent")
    end

    test "unset, a subject is named by its key exactly as it always was" do
      assert_nil Concierge.config.subject_label
      assert_equal "account##{@tenant.id}", SubjectLabel.for(@row)
    end

    test "set, the host's label names the subject" do
      Concierge.config.subject_label = ->(subject) { Tenant.find_by(id: subject.id)&.name }

      assert_equal "Crossroads Commons", SubjectLabel.for(@row)
    end

    test "the callable is handed the key pair, and nothing else" do
      seen = nil
      Concierge.config.subject_label = ->(subject) { seen = subject; "x" }
      SubjectLabel.for(@row)

      assert_equal "account", seen.type
      assert_equal @tenant.id.to_s, seen.id
      assert_equal "account", seen.subject_type
      assert_equal @tenant.id.to_s, seen.subject_id
      assert_equal({ subject_type: "account", subject_id: @tenant.id.to_s }, seen.key)
    end

    test "a label of nil falls back to the key" do
      Concierge.config.subject_label = ->(_subject) { nil }

      assert_equal "account##{@tenant.id}", SubjectLabel.for(@row)
    end

    test "a label of empty string, or only whitespace, falls back to the key" do
      Concierge.config.subject_label = ->(_subject) { "" }
      assert_equal "account##{@tenant.id}", SubjectLabel.for(@row)

      Concierge.config.subject_label = ->(_subject) { "   " }
      assert_equal "account##{@tenant.id}", SubjectLabel.for(@row)
    end

    test "a raising callable falls back to the key, logs, and lets no exception out" do
      Concierge.config.subject_label = ->(_subject) { raise ArgumentError, "no such Property" }
      Concierge.config.logger = log = ArrayLogger.new

      assert_equal "account##{@tenant.id}", SubjectLabel.for(@row)

      assert_equal 1, log.warnings.size
      assert_match "config.subject_label raised for account##{@tenant.id}", log.warnings.first
      assert_match "ArgumentError: no such Property", log.warnings.first
    end

    test "a raising callable logs once per resolution, not once per row" do
      # A broken lambda on a hundred-row queue is one bug. A hundred identical
      # warnings is how the trace of it gets scrolled past.
      Concierge.config.subject_label = ->(_subject) { raise "boom" }
      Concierge.config.logger = log = ArrayLogger.new

      resolver = SubjectLabel::Resolver.new
      20.times { |i| resolver.label("account", i.to_s) }

      assert_equal 1, log.warnings.size
    end

    test "a resolver asks the host once per distinct subject, however many rows name it" do
      asked = []
      Concierge.config.subject_label = ->(subject) { asked << subject.id; "Account #{subject.id}" }

      resolver = SubjectLabel::Resolver.new
      50.times { resolver.label("account", "1") }
      50.times { resolver.label("account", "2") }

      assert_equal %w[1 2], asked
    end

    test "a resolver caches a fallback too, so a raising lambda is not re-run per row" do
      calls = 0
      Concierge.config.subject_label = ->(_subject) { calls += 1; raise "boom" }

      resolver = SubjectLabel::Resolver.new
      10.times { assert_equal "account#7", resolver.label("account", "7") }

      assert_equal 1, calls
    end

    test "a caller may keep its own historical wording as the fallback" do
      # Back-compat: the Slack card has always said "account #7", with a space.
      # An unset hook must not move a byte of that.
      assert_equal "account #7", SubjectLabel.for_key("account", "7", fallback: "account #7")

      Concierge.config.subject_label = ->(_subject) { "Crossroads Commons" }
      assert_equal "Crossroads Commons", SubjectLabel.for_key("account", "7", fallback: "account #7")
    end

    test "a Concierge::Subject names itself by grain and id like any row" do
      Concierge.config.subject_label = ->(subject) { "#{subject.type}/#{subject.id}" }
      subject = Concierge.config.account.build(@tenant)

      assert_equal "account/#{@tenant.id}", SubjectLabel.for(subject)
    end

    test "the label is display only — there is no way to ask for a subject by one" do
      # The whole point of constraint 1. (subject_type, subject_id) stays the one
      # key; a caption a host writes must never become something a caller can
      # present as identity.
      refute SubjectLabel.respond_to?(:find_by_label)
      refute SubjectLabel.respond_to?(:subject_for)
      refute SubjectLabel::Resolver.instance_methods.any? { |m| m.to_s.start_with?("find") }
    end

    # A logger that keeps what it was told, so a test can assert on the trace
    # rather than on the absence of a crash.
    class ArrayLogger
      attr_reader :warnings

      def initialize = @warnings = []
      def warn(message) = @warnings << message.to_s
      def info(_message) = nil
      def debug(_message) = nil
      def error(_message) = nil
    end
  end
end
