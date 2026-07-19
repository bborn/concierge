# This migration comes from concierge (originally 20260101000007)
class CreateConciergeBudgetLedgers < ActiveRecord::Migration[7.1]
  def change
    create_table :concierge_budget_ledgers do |t|
      t.string   :subject_type, null: false
      t.string   :subject_id,   null: false
      t.date     :window_on,    null: false
      t.integer  :tokens_spent, null: false, default: 0
      t.timestamps
    end

    add_index :concierge_budget_ledgers, [ :subject_type, :subject_id, :window_on ],
      unique: true, name: "index_concierge_budget_ledgers_on_subject_window"
  end
end
