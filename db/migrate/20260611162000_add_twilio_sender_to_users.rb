class AddTwilioSenderToUsers < ActiveRecord::Migration[8.1]
  def change
    add_column :users, :twilio_from_number, :string
    add_column :users, :twilio_messaging_service_sid, :string
    add_index :users, :twilio_from_number
    add_index :users, :twilio_messaging_service_sid
  end
end
