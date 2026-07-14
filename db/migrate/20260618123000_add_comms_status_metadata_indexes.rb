class AddCommsStatusMetadataIndexes < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def change
    add_index :crm_record_artifacts,
      "(metadata ->> 'stage_type')",
      name: "idx_comm_artifacts_stage_type",
      algorithm: :concurrently,
      if_not_exists: true

    add_index :crm_record_artifacts,
      "(metadata ->> 'comms_board_state')",
      name: "idx_comm_artifacts_board_state",
      algorithm: :concurrently,
      if_not_exists: true

    add_index :crm_record_artifacts,
      "(metadata ->> 'comms_command_last_status')",
      name: "idx_comm_artifacts_last_status",
      algorithm: :concurrently,
      if_not_exists: true

    add_index :crm_record_artifacts,
      "(metadata ->> 'comms_command_last_channel')",
      name: "idx_comm_artifacts_last_channel",
      algorithm: :concurrently,
      if_not_exists: true

    add_index :crm_record_artifacts,
      "(metadata ->> 'sms_autopilot_enabled')",
      name: "idx_comm_artifacts_sms_autopilot",
      algorithm: :concurrently,
      if_not_exists: true

    add_index :crm_record_artifacts,
      :metadata,
      using: :gin,
      name: "idx_comm_artifacts_metadata_gin",
      algorithm: :concurrently,
      if_not_exists: true
  end
end
