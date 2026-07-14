class AddCommsOwnerMetadataIndexes < ActiveRecord::Migration[8.1]
  def change
    add_index :crm_record_artifacts,
      "(metadata ->> 'hubspot_lead_owner')",
      name: "idx_comm_artifacts_hubspot_lead_owner"

    add_index :crm_record_artifacts,
      "(metadata ->> 'processing_code')",
      name: "idx_comm_artifacts_processing_code"

    add_index :crm_record_artifacts,
      "(metadata ->> 'product_interest_code')",
      name: "idx_comm_artifacts_product_interest"

    add_index :crm_record_artifacts,
      "(metadata ->> 'comms_routed_to_user_id')",
      name: "idx_comm_artifacts_routed_user"
  end
end
