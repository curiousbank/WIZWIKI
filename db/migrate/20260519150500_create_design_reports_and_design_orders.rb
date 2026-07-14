class CreateDesignReportsAndDesignOrders < ActiveRecord::Migration[8.1]
  def change
    create_table :design_reports do |t|
      t.references :organization, null: false, foreign_key: true
      t.references :user, null: false, foreign_key: true
      t.string :title, null: false
      t.string :file_name
      t.string :content_type
      t.integer :byte_size, null: false, default: 0
      t.integer :row_count, null: false, default: 0
      t.jsonb :headers, null: false, default: []
      t.string :status, null: false, default: "imported"
      t.jsonb :metadata, null: false, default: {}

      t.timestamps
    end

    add_index :design_reports, [:organization_id, :created_at]
    add_index :design_reports, [:organization_id, :status]

    create_table :design_orders do |t|
      t.references :organization, null: false, foreign_key: true
      t.references :design_report, null: false, foreign_key: true
      t.references :user, null: false, foreign_key: true
      t.string :source_uid, null: false
      t.string :order_number
      t.string :item_name, null: false
      t.string :designer_name
      t.string :product_name
      t.integer :biz_days_in_stage
      t.integer :biz_days_overall
      t.integer :revisions, null: false, default: 0
      t.string :customer_email
      t.date :start_date
      t.string :monday_url
      t.string :stage, null: false, default: "design"
      t.string :status, null: false, default: "open"
      t.integer :row_number, null: false, default: 0
      t.jsonb :raw_payload, null: false, default: {}

      t.timestamps
    end

    add_index :design_orders, [:organization_id, :source_uid], unique: true
    add_index :design_orders, [:organization_id, :order_number]
    add_index :design_orders, [:organization_id, :designer_name]
    add_index :design_orders, [:organization_id, :product_name]
    add_index :design_orders, [:organization_id, :status]
    add_index :design_orders, [:design_report_id, :row_number]
    add_index :design_orders, :raw_payload, using: :gin
  end
end
