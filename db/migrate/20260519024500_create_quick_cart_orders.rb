class CreateQuickCartOrders < ActiveRecord::Migration[8.1]
  def change
    create_table :quick_cart_orders do |t|
      t.references :organization, null: false, foreign_key: true
      t.references :crm_record, null: false, foreign_key: true
      t.string :package, null: false
      t.string :email
      t.string :phone
      t.integer :amount_cents, null: false, default: 0
      t.string :currency, null: false, default: "USD"
      t.string :status, null: false, default: "created"
      t.string :square_payment_id
      t.string :square_order_id
      t.string :square_receipt_url
      t.string :square_status
      t.string :card_brand
      t.string :card_last_4
      t.text :error_message
      t.jsonb :metadata, null: false, default: {}
      t.timestamps
    end

    add_index :quick_cart_orders, :status
    add_index :quick_cart_orders, :package
    add_index :quick_cart_orders, :square_payment_id, unique: true, where: "square_payment_id IS NOT NULL"
  end
end
