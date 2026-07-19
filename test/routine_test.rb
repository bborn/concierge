require "test_helper"

module Concierge
  class RoutineTest < ActiveSupport::TestCase
    setup do
      @tenant  = Tenant.create!(name: "Acme", plan: "pro")
      @subject = Concierge.config.account.build(@tenant)
    end

    test "sets next_run_at from a cron schedule on create" do
      routine = Routine.create!(subject_type: "account", subject_id: @tenant.id.to_s,
                                schedule: "0 9 * * 1", instruction: "weekly report")
      assert routine.next_run_at.present?
    end

    test "rejects an unschedulable expression" do
      routine = Routine.new(subject_type: "account", subject_id: @tenant.id.to_s,
                            schedule: "not a schedule", instruction: "x")
      refute routine.valid?
      assert_includes routine.errors.attribute_names, :schedule
    end

    test "due scope and due? honor next_run_at and enabled" do
      past = Routine.create!(subject_type: "account", subject_id: @tenant.id.to_s,
                             schedule: "0 9 * * 1", instruction: "x", next_run_at: 1.hour.ago)
      future = Routine.create!(subject_type: "account", subject_id: @tenant.id.to_s,
                               schedule: "0 9 * * 1", instruction: "y", next_run_at: 1.hour.from_now)

      assert_includes Routine.due, past
      refute_includes Routine.due, future
      assert past.due?
      refute future.due?
    end

    test "advance! moves next_run_at forward" do
      routine = Routine.create!(subject_type: "account", subject_id: @tenant.id.to_s,
                                schedule: "0 9 * * 1", instruction: "x", next_run_at: 1.hour.ago)
      routine.advance!(Time.current)
      assert routine.next_run_at > Time.current
    end

    test "manage_routine tool CRUD works and records the author" do
      tool = Tools::RoutineTool.new(subject: @subject)

      created = tool.execute(action: "create", schedule: "0 9 * * 1",
                             instruction: "send weekly report", author: "customer")
      assert created[:ok]
      routine = Routine.find(created[:id])
      assert_equal "customer", routine.author

      tool.execute(action: "update", id: routine.id, instruction: "send monthly report")
      assert_equal "send monthly report", routine.reload.instruction

      assert_equal 1, tool.execute(action: "list").size

      tool.execute(action: "destroy", id: routine.id)
      refute Routine.exists?(routine.id)
    end

    test "manage_routine is scoped to the subject" do
      other = Tenant.create!(name: "Beta")
      foreign = Routine.create!(subject_type: "account", subject_id: other.id.to_s,
                                schedule: "0 9 * * 1", instruction: "beta")

      result = Tools::RoutineTool.new(subject: @subject).execute(action: "destroy", id: foreign.id)
      assert result[:error]
      assert Routine.exists?(foreign.id)
    end
  end
end
