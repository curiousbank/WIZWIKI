class AddAdminFlagAndNormalizeMembershipRoles < ActiveRecord::Migration[8.1]
  def up
    add_column :memberships, :admin, :boolean, default: false, null: false unless column_exists?(:memberships, :admin)
    change_column_default :memberships, :role, from: "scribe", to: "produce"

    execute <<~SQL.squish
      UPDATE memberships
      SET
        admin = CASE WHEN role IN ('owner', 'admin') THEN TRUE ELSE admin END,
        role = CASE
          WHEN role IN ('owner', 'admin', 'developer') THEN 'develop'
          WHEN role = 'designer' THEN 'design'
          WHEN role IN ('design', 'develop', 'produce') THEN role
          ELSE 'produce'
        END
    SQL
  end

  def down
    execute <<~SQL.squish
      UPDATE memberships
      SET role = CASE
        WHEN role = 'develop' AND admin = TRUE THEN 'admin'
        WHEN role = 'develop' THEN 'developer'
        WHEN role = 'design' THEN 'designer'
        ELSE 'scribe'
      END
    SQL

    change_column_default :memberships, :role, from: "produce", to: "scribe"
    remove_column :memberships, :admin if column_exists?(:memberships, :admin)
  end
end
