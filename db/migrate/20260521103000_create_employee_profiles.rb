class CreateEmployeeProfiles < ActiveRecord::Migration[8.1]
  def change
    create_table :employee_profiles do |t|
      t.references :organization, null: false, foreign_key: true
      t.references :user, foreign_key: true
      t.string :source_key, null: false
      t.string :first_name
      t.string :last_name
      t.string :email
      t.string :role_title
      t.string :team_name
      t.string :department
      t.string :reports_to_name
      t.string :location
      t.boolean :leadership, default: false, null: false
      t.boolean :executive, default: false, null: false
      t.string :computer
      t.date :start_date
      t.string :tenure_text
      t.boolean :ten_months_plus
      t.string :employee_status
      t.string :wizwiki_status
      t.string :clifton_status
      t.date :strengths_taken_on
      t.string :strength_1
      t.string :strength_2
      t.string :strength_3
      t.string :strength_4
      t.string :strength_5
      t.jsonb :strengths, default: [], null: false
      t.string :recommended_role, default: "produce", null: false
      t.integer :admin_level, default: 0, null: false
      t.text :admin_recommendation
      t.string :invitation_status, default: "not_sent", null: false
      t.string :invitation_token_digest
      t.datetime :invitation_sent_at
      t.datetime :invitation_accepted_at
      t.jsonb :raw_payload, default: {}, null: false

      t.timestamps
    end

    add_index :employee_profiles, [:organization_id, :source_key], unique: true
    add_index :employee_profiles, [:organization_id, :email], unique: true, where: "email IS NOT NULL"
    add_index :employee_profiles, [:organization_id, :last_name, :first_name]
    add_index :employee_profiles, [:organization_id, :department]
    add_index :employee_profiles, [:organization_id, :team_name]
    add_index :employee_profiles, [:organization_id, :recommended_role]
    add_index :employee_profiles, [:organization_id, :admin_level]
    add_index :employee_profiles, [:organization_id, :strength_1]
    add_index :employee_profiles, [:organization_id, :strength_2]
    add_index :employee_profiles, [:organization_id, :strength_3]
    add_index :employee_profiles, :strengths, using: :gin
  end
end
