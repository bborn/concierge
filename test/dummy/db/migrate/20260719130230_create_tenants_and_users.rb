class CreateTenantsAndUsers < ActiveRecord::Migration[8.1]
  def change
    create_table :tenants do |t|
      t.string :name
      t.string :plan
      t.datetime :last_active_at
      t.timestamps
    end

    create_table :users do |t|
      t.references :tenant, null: false, foreign_key: true
      t.string :email
      t.timestamps
    end
  end
end
