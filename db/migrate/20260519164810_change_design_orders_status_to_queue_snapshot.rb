class ChangeDesignOrdersStatusToQueueSnapshot < ActiveRecord::Migration[8.1]
  def up
    change_column_default :design_orders, :status, from: "open", to: nil
    change_column_null :design_orders, :status, true
    execute "UPDATE design_orders SET status = NULL WHERE status = 'open'"
  end

  def down
    execute "UPDATE design_orders SET status = 'open' WHERE status IS NULL"
    change_column_null :design_orders, :status, false
    change_column_default :design_orders, :status, from: nil, to: "open"
  end
end
