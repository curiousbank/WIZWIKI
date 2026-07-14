class AddAircallRoutingToUsers < ActiveRecord::Migration[8.1]
  def change
    add_column :users, :aircall_user_id, :string
    add_column :users, :aircall_number_id, :string
    add_column :users, :aircall_external_key, :string
    add_index :users, :aircall_external_key
  end
end
