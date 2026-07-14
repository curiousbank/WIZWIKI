# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[8.1].define(version: 2026_07_14_153000) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "pg_catalog.plpgsql"
  enable_extension "vector"

  create_table "active_storage_attachments", force: :cascade do |t|
    t.bigint "blob_id", null: false
    t.datetime "created_at", null: false
    t.string "name", null: false
    t.bigint "record_id", null: false
    t.string "record_type", null: false
    t.index ["blob_id"], name: "index_active_storage_attachments_on_blob_id"
    t.index ["record_type", "record_id", "name", "blob_id"], name: "index_active_storage_attachments_uniqueness", unique: true
  end

  create_table "active_storage_blobs", force: :cascade do |t|
    t.bigint "byte_size", null: false
    t.string "checksum"
    t.string "content_type"
    t.datetime "created_at", null: false
    t.string "filename", null: false
    t.string "key", null: false
    t.text "metadata"
    t.string "service_name", null: false
    t.index ["key"], name: "index_active_storage_blobs_on_key", unique: true
  end

  create_table "active_storage_variant_records", force: :cascade do |t|
    t.bigint "blob_id", null: false
    t.string "variation_digest", null: false
    t.index ["blob_id", "variation_digest"], name: "index_active_storage_variant_records_uniqueness", unique: true
  end

  create_table "autos_embedding_chunks", force: :cascade do |t|
    t.integer "attempts", default: 0, null: false
    t.integer "chunk_index", default: 0, null: false
    t.datetime "claimed_at"
    t.text "content", null: false
    t.string "content_digest", null: false
    t.datetime "created_at", null: false
    t.datetime "embedded_at"
    t.vector "embedding"
    t.integer "embedding_dimensions"
    t.string "embedding_model", null: false
    t.string "label"
    t.text "last_error"
    t.jsonb "metadata", default: {}, null: false
    t.bigint "organization_id", null: false
    t.string "scope", default: "wizwiki", null: false
    t.string "source_digest", null: false
    t.bigint "source_id", null: false
    t.string "source_type", null: false
    t.string "status", default: "pending", null: false
    t.datetime "updated_at", null: false
    t.string "worker_id"
    t.index ["content_digest"], name: "index_autos_embedding_chunks_on_content_digest"
    t.index ["embedding_model", "status", "updated_at", "id"], name: "idx_autos_embedding_chunks_claim_queue", where: "((status)::text = ANY (ARRAY[('pending'::character varying)::text, ('claimed'::character varying)::text]))"
    t.index ["embedding_model", "status", "updated_at", "id"], name: "idx_autos_embedding_chunks_stale_prune", where: "((status)::text = 'stale'::text)"
    t.index ["organization_id", "scope", "embedding_model", "embedding_dimensions", "status"], name: "idx_autos_embedding_chunks_search_filter"
    t.index ["organization_id", "source_type", "source_id", "chunk_index", "embedding_model"], name: "idx_autos_embedding_chunks_unique_source", unique: true
    t.index ["organization_id"], name: "index_autos_embedding_chunks_on_organization_id"
    t.index ["source_digest"], name: "index_autos_embedding_chunks_on_source_digest"
  end

  create_table "autos_questions", force: :cascade do |t|
    t.text "answer"
    t.text "context"
    t.datetime "created_at", null: false
    t.jsonb "metadata", default: {}, null: false
    t.bigint "organization_id", null: false
    t.text "question", null: false
    t.string "status", default: "queued", null: false
    t.datetime "updated_at", null: false
    t.bigint "user_id", null: false
    t.index ["organization_id", "status"], name: "index_autos_questions_on_organization_id_and_status"
    t.index ["organization_id", "user_id", "created_at"], name: "idx_on_organization_id_user_id_created_at_2ebf6e2714"
    t.index ["organization_id"], name: "index_autos_questions_on_organization_id"
    t.index ["user_id"], name: "index_autos_questions_on_user_id"
  end

  create_table "build_requests", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.jsonb "metadata", default: {}, null: false
    t.bigint "organization_id", null: false
    t.text "prompt", null: false
    t.string "status", default: "staged", null: false
    t.string "target_area", null: false
    t.string "title", null: false
    t.datetime "updated_at", null: false
    t.bigint "user_id", null: false
    t.index ["organization_id", "status"], name: "index_build_requests_on_organization_id_and_status"
    t.index ["organization_id", "user_id", "created_at"], name: "idx_on_organization_id_user_id_created_at_33def66ad0"
    t.index ["organization_id"], name: "index_build_requests_on_organization_id"
    t.index ["user_id"], name: "index_build_requests_on_user_id"
  end

  create_table "canva_connections", force: :cascade do |t|
    t.text "access_token"
    t.datetime "access_token_expires_at"
    t.datetime "authorized_at"
    t.string "code_verifier"
    t.datetime "created_at", null: false
    t.jsonb "metadata", default: {}, null: false
    t.bigint "organization_id", null: false
    t.text "refresh_token"
    t.text "scope"
    t.string "state"
    t.string "status", default: "pending", null: false
    t.datetime "updated_at", null: false
    t.bigint "user_id", null: false
    t.index ["organization_id", "user_id"], name: "index_canva_connections_on_organization_id_and_user_id", unique: true
    t.index ["organization_id"], name: "index_canva_connections_on_organization_id"
    t.index ["state"], name: "index_canva_connections_on_state", unique: true, where: "(state IS NOT NULL)"
    t.index ["status"], name: "index_canva_connections_on_status"
    t.index ["user_id"], name: "index_canva_connections_on_user_id"
  end

  create_table "comms_board_rollups", primary_key: "crm_record_artifact_id", id: :bigint, default: nil, force: :cascade do |t|
    t.boolean "active_visible", default: false, null: false
    t.boolean "included", default: false, null: false
    t.bigint "organization_id", null: false
    t.timestamptz "source_updated_at"
    t.string "status_key"
    t.boolean "storm_watch", default: false, null: false
    t.timestamptz "synced_at", default: -> { "CURRENT_TIMESTAMP" }, null: false
    t.boolean "owner_queue", default: false, null: false
    t.index ["organization_id", "included", "status_key"], name: "idx_comms_board_rollups_counts", include: ["active_visible", "owner_queue", "storm_watch"]
  end

  create_table "crm_address_records", force: :cascade do |t|
    t.string "address1"
    t.string "address2"
    t.string "address_kind", default: "address", null: false
    t.string "address_line"
    t.string "address_one_line", null: false
    t.jsonb "association_context", default: {}, null: false
    t.string "city"
    t.integer "confidence", default: 50, null: false
    t.string "country"
    t.datetime "created_at", null: false
    t.bigint "crm_record_id"
    t.jsonb "metadata", default: {}, null: false
    t.string "normalized_key", null: false
    t.bigint "organization_id", null: false
    t.bigint "playbook_call_id"
    t.string "postal_code"
    t.jsonb "raw_components", default: {}, null: false
    t.string "record_type"
    t.bigint "source_id"
    t.string "source_key", null: false
    t.string "source_label"
    t.string "source_path", null: false
    t.string "source_type", null: false
    t.string "state"
    t.datetime "updated_at", null: false
    t.index ["association_context"], name: "index_crm_address_records_on_association_context", using: :gin
    t.index ["crm_record_id"], name: "index_crm_address_records_on_crm_record_id"
    t.index ["organization_id", "city", "state"], name: "idx_on_organization_id_city_state_f9e62c02a0"
    t.index ["organization_id", "normalized_key"], name: "idx_on_organization_id_normalized_key_aedfbb3bd0"
    t.index ["organization_id", "postal_code"], name: "index_crm_address_records_on_organization_id_and_postal_code"
    t.index ["organization_id", "source_key", "source_path"], name: "idx_crm_address_records_unique_source_path", unique: true
    t.index ["organization_id"], name: "index_crm_address_records_on_organization_id"
    t.index ["playbook_call_id"], name: "index_crm_address_records_on_playbook_call_id"
    t.index ["raw_components"], name: "index_crm_address_records_on_raw_components", using: :gin
  end

  create_table "crm_associations", force: :cascade do |t|
    t.string "association_type", null: false
    t.datetime "created_at", null: false
    t.bigint "from_record_id", null: false
    t.bigint "organization_id", null: false
    t.bigint "to_record_id", null: false
    t.datetime "updated_at", null: false
    t.index ["from_record_id"], name: "index_crm_associations_on_from_record_id"
    t.index ["organization_id", "association_type"], name: "index_crm_associations_on_organization_id_and_association_type"
    t.index ["organization_id", "from_record_id", "to_record_id", "association_type"], name: "idx_crm_associations_unique_edge", unique: true
    t.index ["organization_id"], name: "index_crm_associations_on_organization_id"
    t.index ["to_record_id"], name: "index_crm_associations_on_to_record_id"
  end

  create_table "crm_property_definitions", force: :cascade do |t|
    t.boolean "active", default: true, null: false
    t.datetime "created_at", null: false
    t.string "data_type", default: "text", null: false
    t.string "key", null: false
    t.string "label", null: false
    t.jsonb "options", default: {}, null: false
    t.bigint "organization_id", null: false
    t.string "record_type", null: false
    t.boolean "required", default: false, null: false
    t.boolean "unique_value", default: false, null: false
    t.datetime "updated_at", null: false
    t.index ["organization_id", "record_type", "key"], name: "idx_crm_property_definitions_unique_key", unique: true
    t.index ["organization_id"], name: "index_crm_property_definitions_on_organization_id"
  end

  create_table "crm_record_artifacts", force: :cascade do |t|
    t.string "artifact_type", default: "market_report", null: false
    t.bigint "byte_size"
    t.string "content_type"
    t.datetime "created_at", null: false
    t.bigint "crm_record_id", null: false
    t.string "file_url"
    t.datetime "generated_at"
    t.jsonb "metadata", default: {}, null: false
    t.bigint "organization_id", null: false
    t.string "status", default: "queued", null: false
    t.string "storage_bucket"
    t.string "storage_key"
    t.string "storage_provider"
    t.string "title", null: false
    t.datetime "updated_at", null: false
    t.bigint "user_id"
    t.index "((metadata ->> 'comms_board_state'::text))", name: "idx_comm_artifacts_board_state"
    t.index "((metadata ->> 'comms_command_last_channel'::text))", name: "idx_comm_artifacts_last_channel"
    t.index "((metadata ->> 'comms_command_last_status'::text))", name: "idx_comm_artifacts_last_status"
    t.index "((metadata ->> 'comms_routed_to_user_id'::text))", name: "idx_comm_artifacts_routed_user"
    t.index "((metadata ->> 'hubspot_lead_owner'::text))", name: "idx_comm_artifacts_hubspot_lead_owner"
    t.index "((metadata ->> 'processing_code'::text))", name: "idx_comm_artifacts_processing_code"
    t.index "((metadata ->> 'product_interest_code'::text))", name: "idx_comm_artifacts_product_interest"
    t.index "((metadata ->> 'sms_autopilot_enabled'::text))", name: "idx_comm_artifacts_sms_autopilot"
    t.index "((metadata ->> 'stage_type'::text))", name: "idx_comm_artifacts_stage_type"
    t.index "organization_id, ((metadata ->> 'claimed_by_user_id'::text)), updated_at DESC", name: "idx_comm_active_claimed_user", where: "(((artifact_type)::text = 'comm_staging'::text) AND ((status)::text = ANY (ARRAY[('staged'::character varying)::text, ('aircall_ready'::character varying)::text, ('aircall_sent'::character varying)::text, ('aircall_failed'::character varying)::text])) AND ((metadata ->> 'stage_type'::text) = ANY (ARRAY['manual_comms'::text, 'storm_watch_comms'::text])) AND (NULLIF((metadata ->> 'claimed_by_user_id'::text), ''::text) IS NOT NULL))"
    t.index "organization_id, ((metadata ->> 'csv_call_import_source'::text)), updated_at DESC", name: "idx_comm_artifacts_source_updated", where: "(((artifact_type)::text = 'comm_staging'::text) AND ((status)::text = ANY (ARRAY[('staged'::character varying)::text, ('aircall_ready'::character varying)::text, ('aircall_sent'::character varying)::text, ('aircall_failed'::character varying)::text])))"
    t.index "organization_id, ((metadata ->> 'manual_comms_contact_email'::text)), updated_at DESC", name: "idx_comm_active_contact_email", where: "(((artifact_type)::text = 'comm_staging'::text) AND ((status)::text <> 'archived'::text) AND ((metadata ->> 'stage_type'::text) = ANY (ARRAY['manual_comms'::text, 'storm_watch_comms'::text])) AND (NULLIF((metadata ->> 'manual_comms_contact_email'::text), ''::text) IS NOT NULL))"
    t.index "organization_id, ((metadata ->> 'manual_comms_contact_phone_digits'::text)), updated_at DESC", name: "idx_comm_active_contact_phone", where: "(((artifact_type)::text = 'comm_staging'::text) AND ((status)::text <> 'archived'::text) AND ((metadata ->> 'stage_type'::text) = ANY (ARRAY['manual_comms'::text, 'storm_watch_comms'::text])) AND (NULLIF((metadata ->> 'manual_comms_contact_phone_digits'::text), ''::text) IS NOT NULL))"
    t.index "organization_id, ((metadata ->> 'stage_type'::text)), updated_at DESC", name: "idx_comm_artifacts_stage_updated", where: "(((artifact_type)::text = 'comm_staging'::text) AND ((status)::text = ANY (ARRAY[('staged'::character varying)::text, ('aircall_ready'::character varying)::text, ('aircall_sent'::character varying)::text, ('aircall_failed'::character varying)::text])))"
    t.index ["crm_record_id", "artifact_type"], name: "index_crm_record_artifacts_on_crm_record_id_and_artifact_type"
    t.index ["crm_record_id"], name: "index_crm_record_artifacts_on_crm_record_id"
    t.index ["metadata"], name: "idx_comm_artifacts_metadata_gin", using: :gin
    t.index ["organization_id", "artifact_type", "status"], name: "idx_crm_record_artifacts_queue"
    t.index ["organization_id", "updated_at", "id"], name: "idx_comm_board_change_token", order: { updated_at: :desc, id: :desc }, where: "(((artifact_type)::text = 'comm_staging'::text) AND ((status)::text = ANY (ARRAY[('staged'::character varying)::text, ('aircall_ready'::character varying)::text, ('aircall_sent'::character varying)::text, ('aircall_failed'::character varying)::text])) AND ((metadata ->> 'stage_type'::text) = ANY (ARRAY['manual_comms'::text, 'storm_watch_comms'::text])))"
    t.index ["organization_id"], name: "index_crm_record_artifacts_on_organization_id"
    t.index ["storage_key"], name: "index_crm_record_artifacts_on_storage_key"
    t.index ["user_id"], name: "index_crm_record_artifacts_on_user_id"
  end

  create_table "crm_records", force: :cascade do |t|
    t.decimal "amount", precision: 12, scale: 2
    t.date "close_date"
    t.datetime "created_at", null: false
    t.string "domain"
    t.string "email"
    t.string "fingerprint"
    t.string "name", null: false
    t.bigint "organization_id", null: false
    t.bigint "owner_id"
    t.string "phone"
    t.string "priority_level", default: "normal", null: false
    t.datetime "priority_marked_at"
    t.bigint "priority_marked_by_id"
    t.text "priority_note"
    t.jsonb "properties", default: {}, null: false
    t.string "record_type", null: false
    t.string "source"
    t.string "source_uid"
    t.string "stage"
    t.string "status", default: "open", null: false
    t.datetime "updated_at", null: false
    t.index "organization_id, ((properties ->> 'manual_comms_contact_email'::text)), updated_at DESC", name: "idx_manual_comms_record_email", where: "(((source)::text = 'manual_comms'::text) AND (NULLIF((properties ->> 'manual_comms_contact_email'::text), ''::text) IS NOT NULL))"
    t.index "organization_id, ((properties ->> 'manual_comms_contact_phone_digits'::text)), updated_at DESC", name: "idx_manual_comms_record_phone", where: "(((source)::text = 'manual_comms'::text) AND (NULLIF((properties ->> 'manual_comms_contact_phone_digits'::text), ''::text) IS NOT NULL))"
    t.index ["organization_id", "record_type", "domain"], name: "idx_on_organization_id_record_type_domain_f36bc451f1"
    t.index ["organization_id", "record_type", "email"], name: "index_crm_records_on_organization_id_and_record_type_and_email"
    t.index ["organization_id", "record_type", "fingerprint"], name: "idx_on_organization_id_record_type_fingerprint_d2a93252d8", unique: true
    t.index ["organization_id", "record_type", "phone"], name: "index_crm_records_on_organization_id_and_record_type_and_phone"
    t.index ["organization_id", "record_type", "priority_level"], name: "idx_crm_records_priority_queue"
    t.index ["organization_id", "record_type"], name: "index_crm_records_on_organization_id_and_record_type"
    t.index ["organization_id", "source", "source_uid"], name: "index_crm_records_on_organization_id_and_source_and_source_uid", unique: true, where: "((source IS NOT NULL) AND (source_uid IS NOT NULL))"
    t.index ["organization_id"], name: "index_crm_records_on_organization_id"
    t.index ["owner_id"], name: "index_crm_records_on_owner_id"
    t.index ["priority_marked_by_id"], name: "index_crm_records_on_priority_marked_by_id"
    t.index ["properties"], name: "index_crm_records_on_properties", using: :gin
  end

  create_table "design_orders", force: :cascade do |t|
    t.integer "biz_days_in_stage"
    t.integer "biz_days_overall"
    t.datetime "created_at", null: false
    t.string "customer_email"
    t.bigint "design_report_id", null: false
    t.string "designer_name"
    t.string "item_name", null: false
    t.string "monday_url"
    t.string "order_number"
    t.bigint "organization_id", null: false
    t.string "product_name"
    t.jsonb "raw_payload", default: {}, null: false
    t.integer "revisions", default: 0, null: false
    t.integer "row_number", default: 0, null: false
    t.string "source_uid", null: false
    t.string "stage", default: "design", null: false
    t.date "start_date"
    t.string "status"
    t.datetime "updated_at", null: false
    t.bigint "user_id", null: false
    t.index ["design_report_id", "row_number"], name: "index_design_orders_on_design_report_id_and_row_number"
    t.index ["design_report_id"], name: "index_design_orders_on_design_report_id"
    t.index ["organization_id", "designer_name"], name: "index_design_orders_on_organization_id_and_designer_name"
    t.index ["organization_id", "order_number"], name: "index_design_orders_on_organization_id_and_order_number"
    t.index ["organization_id", "product_name"], name: "index_design_orders_on_organization_id_and_product_name"
    t.index ["organization_id", "source_uid"], name: "index_design_orders_on_organization_id_and_source_uid", unique: true
    t.index ["organization_id", "status"], name: "index_design_orders_on_organization_id_and_status"
    t.index ["organization_id"], name: "index_design_orders_on_organization_id"
    t.index ["raw_payload"], name: "index_design_orders_on_raw_payload", using: :gin
    t.index ["user_id"], name: "index_design_orders_on_user_id"
  end

  create_table "design_reports", force: :cascade do |t|
    t.integer "byte_size", default: 0, null: false
    t.string "content_type"
    t.datetime "created_at", null: false
    t.string "file_name"
    t.jsonb "headers", default: [], null: false
    t.jsonb "metadata", default: {}, null: false
    t.bigint "organization_id", null: false
    t.integer "row_count", default: 0, null: false
    t.string "status", default: "imported", null: false
    t.string "title", null: false
    t.datetime "updated_at", null: false
    t.bigint "user_id", null: false
    t.index ["organization_id", "created_at"], name: "index_design_reports_on_organization_id_and_created_at"
    t.index ["organization_id", "status"], name: "index_design_reports_on_organization_id_and_status"
    t.index ["organization_id"], name: "index_design_reports_on_organization_id"
    t.index ["user_id"], name: "index_design_reports_on_user_id"
  end

  create_table "wizwiki_automation_runs", force: :cascade do |t|
    t.string "automation_key", null: false
    t.datetime "created_at", null: false
    t.string "current_step"
    t.text "error_message"
    t.datetime "finished_at"
    t.jsonb "metadata", default: {}, null: false
    t.bigint "organization_id", null: false
    t.string "request_id"
    t.jsonb "result", default: {}, null: false
    t.string "run_key", null: false
    t.datetime "scheduled_for"
    t.string "solid_queue_job_id"
    t.datetime "started_at"
    t.string "status", default: "queued", null: false
    t.date "target_date"
    t.string "trigger", default: "systemd", null: false
    t.datetime "updated_at", null: false
    t.index ["automation_key", "status"], name: "index_wizwiki_automation_runs_on_automation_key_and_status"
    t.index ["organization_id", "automation_key", "target_date"], name: "idx_on_organization_id_automation_key_target_date_38eef8bda1"
    t.index ["organization_id"], name: "index_wizwiki_automation_runs_on_organization_id"
    t.index ["run_key"], name: "index_wizwiki_automation_runs_on_run_key", unique: true
    t.index ["scheduled_for"], name: "index_wizwiki_automation_runs_on_scheduled_for"
  end

  create_table "duplicate_candidates", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "crm_record_id", null: false
    t.bigint "duplicate_record_id", null: false
    t.bigint "organization_id", null: false
    t.jsonb "reasons", default: [], null: false
    t.decimal "score", precision: 5, scale: 2, default: "0.0", null: false
    t.string "status", default: "open", null: false
    t.datetime "updated_at", null: false
    t.index ["crm_record_id"], name: "index_duplicate_candidates_on_crm_record_id"
    t.index ["duplicate_record_id"], name: "index_duplicate_candidates_on_duplicate_record_id"
    t.index ["organization_id", "crm_record_id", "duplicate_record_id"], name: "idx_duplicate_candidates_unique_pair", unique: true
    t.index ["organization_id", "status"], name: "index_duplicate_candidates_on_organization_id_and_status"
    t.index ["organization_id"], name: "index_duplicate_candidates_on_organization_id"
  end

  create_table "employee_profiles", force: :cascade do |t|
    t.integer "admin_level", default: 0, null: false
    t.text "admin_recommendation"
    t.string "clifton_status"
    t.string "computer"
    t.datetime "created_at", null: false
    t.string "department"
    t.string "wizwiki_status"
    t.string "email"
    t.string "employee_status"
    t.boolean "executive", default: false, null: false
    t.string "first_name"
    t.datetime "invitation_accepted_at"
    t.datetime "invitation_sent_at"
    t.string "invitation_status", default: "not_sent", null: false
    t.string "invitation_token_digest"
    t.string "last_name"
    t.boolean "leadership", default: false, null: false
    t.string "location"
    t.bigint "organization_id", null: false
    t.jsonb "raw_payload", default: {}, null: false
    t.string "recommended_role", default: "produce", null: false
    t.string "reports_to_name"
    t.string "role_title"
    t.string "source_key", null: false
    t.date "start_date"
    t.string "strength_1"
    t.string "strength_2"
    t.string "strength_3"
    t.string "strength_4"
    t.string "strength_5"
    t.jsonb "strengths", default: [], null: false
    t.date "strengths_taken_on"
    t.string "team_name"
    t.boolean "ten_months_plus"
    t.string "tenure_text"
    t.datetime "updated_at", null: false
    t.bigint "user_id"
    t.index ["organization_id", "admin_level"], name: "index_employee_profiles_on_organization_id_and_admin_level"
    t.index ["organization_id", "department"], name: "index_employee_profiles_on_organization_id_and_department"
    t.index ["organization_id", "email"], name: "index_employee_profiles_on_organization_id_and_email", unique: true, where: "(email IS NOT NULL)"
    t.index ["organization_id", "last_name", "first_name"], name: "idx_on_organization_id_last_name_first_name_ad1120a42b"
    t.index ["organization_id", "recommended_role"], name: "idx_on_organization_id_recommended_role_aea8dddc32"
    t.index ["organization_id", "source_key"], name: "index_employee_profiles_on_organization_id_and_source_key", unique: true
    t.index ["organization_id", "strength_1"], name: "index_employee_profiles_on_organization_id_and_strength_1"
    t.index ["organization_id", "strength_2"], name: "index_employee_profiles_on_organization_id_and_strength_2"
    t.index ["organization_id", "strength_3"], name: "index_employee_profiles_on_organization_id_and_strength_3"
    t.index ["organization_id", "team_name"], name: "index_employee_profiles_on_organization_id_and_team_name"
    t.index ["organization_id"], name: "index_employee_profiles_on_organization_id"
    t.index ["strengths"], name: "index_employee_profiles_on_strengths", using: :gin
    t.index ["user_id"], name: "index_employee_profiles_on_user_id"
  end

  create_table "fathom_calls", force: :cascade do |t|
    t.text "action_items_text"
    t.jsonb "calendar_invitees", default: [], null: false
    t.datetime "created_at", null: false
    t.jsonb "crm_matches", default: {}, null: false
    t.datetime "fathom_created_at"
    t.text "highlights_text"
    t.string "meeting_title"
    t.string "meeting_type"
    t.string "meeting_url"
    t.bigint "organization_id", null: false
    t.jsonb "raw_payload", default: {}, null: false
    t.string "recorded_by_email"
    t.string "recorded_by_name"
    t.string "recorded_by_team"
    t.datetime "recording_end_time"
    t.string "recording_id", null: false
    t.datetime "recording_start_time"
    t.datetime "scheduled_end_time"
    t.datetime "scheduled_start_time"
    t.string "share_url"
    t.string "status", default: "synced", null: false
    t.text "summary"
    t.datetime "synced_at"
    t.string "title"
    t.text "transcript"
    t.string "transcript_language"
    t.datetime "updated_at", null: false
    t.string "url"
    t.index ["organization_id", "fathom_created_at"], name: "idx_fathom_calls_org_created_at"
    t.index ["organization_id", "recording_id"], name: "index_fathom_calls_on_organization_id_and_recording_id", unique: true
    t.index ["organization_id", "recording_start_time"], name: "index_fathom_calls_on_organization_id_and_recording_start_time"
    t.index ["organization_id", "status"], name: "index_fathom_calls_on_organization_id_and_status"
    t.index ["organization_id"], name: "index_fathom_calls_on_organization_id"
  end

  create_table "ingestion_events", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "crm_record_id"
    t.bigint "organization_id", null: false
    t.string "payload_digest", null: false
    t.jsonb "raw_payload", default: {}, null: false
    t.string "source", null: false
    t.string "source_uid"
    t.string "status", default: "accepted", null: false
    t.datetime "updated_at", null: false
    t.index ["crm_record_id"], name: "index_ingestion_events_on_crm_record_id"
    t.index ["organization_id", "source", "payload_digest"], name: "idx_ingestion_events_unique_payload", unique: true
    t.index ["organization_id", "source", "source_uid"], name: "idx_on_organization_id_source_source_uid_addde9c227", unique: true, where: "(source_uid IS NOT NULL)"
    t.index ["organization_id"], name: "index_ingestion_events_on_organization_id"
  end

  create_table "kalshi_weather_prediction_snapshots", force: :cascade do |t|
    t.string "action", null: false
    t.integer "adjusted_high_f"
    t.decimal "ask", precision: 8, scale: 4
    t.datetime "captured_at", null: false
    t.decimal "confidence", precision: 8, scale: 4
    t.decimal "confidence_lower_bound", precision: 8, scale: 4
    t.decimal "conservative_edge", precision: 8, scale: 4
    t.datetime "created_at", null: false
    t.decimal "edge", precision: 8, scale: 4
    t.string "event_ticker", null: false
    t.string "feature_digest", null: false
    t.integer "forecast_high_f"
    t.integer "forecast_source_count"
    t.decimal "forecast_source_spread_f", precision: 8, scale: 2
    t.bigint "kalshi_weather_prediction_id", null: false
    t.decimal "market_cap_strike", precision: 8, scale: 2
    t.decimal "market_floor_strike", precision: 8, scale: 2
    t.string "market_ticker", null: false
    t.bigint "organization_id", null: false
    t.jsonb "payload", default: {}, null: false
    t.date "prediction_date", null: false
    t.string "series_ticker", null: false
    t.datetime "updated_at", null: false
    t.index ["kalshi_weather_prediction_id", "feature_digest"], name: "idx_weather_snapshots_unique_features", unique: true
    t.index ["kalshi_weather_prediction_id"], name: "idx_weather_snapshots_prediction"
    t.index ["organization_id", "event_ticker", "captured_at"], name: "idx_weather_snapshots_event_time"
    t.index ["organization_id", "prediction_date", "captured_at"], name: "idx_weather_snapshots_date_time"
    t.index ["organization_id"], name: "index_kalshi_weather_prediction_snapshots_on_organization_id"
  end

  create_table "kalshi_weather_predictions", force: :cascade do |t|
    t.string "action", default: "watch", null: false
    t.integer "adjusted_high_f"
    t.decimal "ask", precision: 8, scale: 4
    t.string "city", null: false
    t.datetime "close_time"
    t.decimal "confidence", precision: 8, scale: 4
    t.datetime "created_at", null: false
    t.decimal "edge", precision: 8, scale: 4
    t.string "event_ticker"
    t.integer "forecast_high_f"
    t.decimal "market_cap_strike", precision: 8, scale: 2
    t.decimal "market_floor_strike", precision: 8, scale: 2
    t.decimal "market_midpoint_f", precision: 8, scale: 2
    t.string "market_range"
    t.string "market_ticker", null: false
    t.text "market_title"
    t.jsonb "metadata", default: {}, null: false
    t.integer "observed_high_f"
    t.bigint "organization_id", null: false
    t.date "prediction_date", null: false
    t.text "rationale"
    t.jsonb "raw_payload", default: {}, null: false
    t.string "result_status", default: "pending", null: false
    t.string "series_ticker", null: false
    t.string "settlement_value"
    t.string "side", default: "YES", null: false
    t.string "size_label", default: "0 contracts", null: false
    t.string "state"
    t.string "status", default: "open", null: false
    t.text "training_note"
    t.datetime "updated_at", null: false
    t.index ["metadata"], name: "index_kalshi_weather_predictions_on_metadata", using: :gin
    t.index ["organization_id", "market_ticker"], name: "idx_kalshi_weather_predictions_unique_market", unique: true
    t.index ["organization_id", "prediction_date"], name: "idx_kalshi_weather_predictions_org_date"
    t.index ["organization_id", "status", "result_status"], name: "idx_kalshi_weather_predictions_status"
    t.index ["organization_id"], name: "index_kalshi_weather_predictions_on_organization_id"
    t.index ["raw_payload"], name: "index_kalshi_weather_predictions_on_raw_payload", using: :gin
    t.index ["series_ticker", "prediction_date"], name: "idx_kalshi_weather_predictions_series_date"
  end

  create_table "kalshi_weather_wagers", force: :cascade do |t|
    t.string "action", default: "buy", null: false
    t.decimal "actual_cost", precision: 12, scale: 2
    t.date "budget_date", null: false
    t.string "client_order_id"
    t.integer "contracts", default: 0, null: false
    t.datetime "created_at", null: false
    t.string "execution_mode", default: "dry_run", null: false
    t.datetime "filled_at"
    t.integer "filled_contracts", default: 0, null: false
    t.string "kalshi_order_id"
    t.bigint "kalshi_weather_prediction_id", null: false
    t.string "market_ticker", null: false
    t.decimal "max_cost", precision: 12, scale: 2, default: "0.0", null: false
    t.jsonb "metadata", default: {}, null: false
    t.string "opportunity_tier"
    t.bigint "organization_id", null: false
    t.datetime "placed_at"
    t.decimal "price", precision: 8, scale: 4
    t.jsonb "raw_payload", default: {}, null: false
    t.decimal "realized_profit", precision: 12, scale: 2
    t.text "reason"
    t.datetime "settled_at"
    t.string "side", default: "yes", null: false
    t.string "status", default: "pending", null: false
    t.string "strategy_key", default: "legacy", null: false
    t.string "strategy_version"
    t.datetime "updated_at", null: false
    t.index ["client_order_id"], name: "index_kalshi_weather_wagers_on_client_order_id", unique: true, where: "(client_order_id IS NOT NULL)"
    t.index ["kalshi_weather_prediction_id"], name: "index_kalshi_weather_wagers_on_kalshi_weather_prediction_id"
    t.index ["organization_id", "budget_date", "status"], name: "idx_kalshi_weather_wagers_budget"
    t.index ["organization_id", "execution_mode", "status", "created_at"], name: "idx_weather_wagers_history"
    t.index ["organization_id", "kalshi_weather_prediction_id", "execution_mode", "strategy_key"], name: "idx_weather_wagers_unique_strategy_lane", unique: true
    t.index ["organization_id", "market_ticker"], name: "idx_kalshi_weather_wagers_market"
    t.index ["organization_id"], name: "index_kalshi_weather_wagers_on_organization_id"
  end

  create_table "memberships", force: :cascade do |t|
    t.boolean "admin", default: false, null: false
    t.datetime "created_at", null: false
    t.bigint "organization_id", null: false
    t.string "role", default: "produce", null: false
    t.string "status", default: "active", null: false
    t.datetime "updated_at", null: false
    t.bigint "user_id", null: false
    t.index ["organization_id", "role"], name: "index_memberships_on_organization_id_and_role"
    t.index ["organization_id"], name: "index_memberships_on_organization_id"
    t.index ["user_id", "organization_id"], name: "index_memberships_on_user_id_and_organization_id", unique: true
    t.index ["user_id"], name: "index_memberships_on_user_id"
  end

  create_table "organizations", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "domain"
    t.string "name", null: false
    t.jsonb "settings", default: {}, null: false
    t.string "slug", null: false
    t.datetime "updated_at", null: false
    t.index ["domain"], name: "index_organizations_on_domain"
    t.index ["slug"], name: "index_organizations_on_slug", unique: true
  end

  create_table "playbook_calls", force: :cascade do |t|
    t.text "analyzer_text"
    t.jsonb "associations", default: {}, null: false
    t.string "call_direction"
    t.string "call_disposition"
    t.string "call_status"
    t.datetime "created_at", null: false
    t.bigint "crm_record_id"
    t.bigint "duration_ms"
    t.boolean "has_transcript", default: false, null: false
    t.string "hubspot_call_id", null: false
    t.datetime "last_synced_at"
    t.string "meeting_id"
    t.jsonb "metadata", default: {}, null: false
    t.text "notes"
    t.datetime "occurred_at"
    t.bigint "organization_id", null: false
    t.string "owner_id"
    t.string "owner_name"
    t.jsonb "playbook_data", default: {}, null: false
    t.jsonb "raw_payload", default: {}, null: false
    t.text "recording_url"
    t.string "status", default: "synced", null: false
    t.text "suggested_next_actions"
    t.text "summary"
    t.string "title"
    t.string "transcription_id"
    t.datetime "updated_at", null: false
    t.text "video_recording_url"
    t.string "zoom_meeting_uuid"
    t.index ["associations"], name: "index_playbook_calls_on_associations", using: :gin
    t.index ["crm_record_id"], name: "index_playbook_calls_on_crm_record_id"
    t.index ["organization_id", "crm_record_id"], name: "index_playbook_calls_on_organization_id_and_crm_record_id"
    t.index ["organization_id", "hubspot_call_id"], name: "index_playbook_calls_on_organization_id_and_hubspot_call_id", unique: true
    t.index ["organization_id", "occurred_at"], name: "index_playbook_calls_on_organization_id_and_occurred_at"
    t.index ["organization_id", "status", "occurred_at"], name: "idx_playbook_calls_active_recent"
    t.index ["organization_id"], name: "index_playbook_calls_on_organization_id"
    t.index ["playbook_data"], name: "index_playbook_calls_on_playbook_data", using: :gin
    t.index ["raw_payload"], name: "index_playbook_calls_on_raw_payload", using: :gin
  end

  create_table "quick_cart_orders", force: :cascade do |t|
    t.integer "amount_cents", default: 0, null: false
    t.string "card_brand"
    t.string "card_last_4"
    t.datetime "created_at", null: false
    t.bigint "crm_record_id", null: false
    t.string "currency", default: "USD", null: false
    t.string "email"
    t.text "error_message"
    t.jsonb "metadata", default: {}, null: false
    t.bigint "organization_id", null: false
    t.string "package", null: false
    t.string "phone"
    t.string "square_order_id"
    t.string "square_payment_id"
    t.string "square_receipt_url"
    t.string "square_status"
    t.string "status", default: "created", null: false
    t.datetime "updated_at", null: false
    t.index ["crm_record_id"], name: "index_quick_cart_orders_on_crm_record_id"
    t.index ["organization_id"], name: "index_quick_cart_orders_on_organization_id"
    t.index ["package"], name: "index_quick_cart_orders_on_package"
    t.index ["square_payment_id"], name: "index_quick_cart_orders_on_square_payment_id", unique: true, where: "(square_payment_id IS NOT NULL)"
    t.index ["status"], name: "index_quick_cart_orders_on_status"
  end

  create_table "sessions", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "ip_address"
    t.datetime "updated_at", null: false
    t.string "user_agent"
    t.bigint "user_id", null: false
    t.index ["user_id"], name: "index_sessions_on_user_id"
  end

  create_table "training_documents", force: :cascade do |t|
    t.text "body", null: false
    t.integer "byte_size", default: 0, null: false
    t.string "content_type"
    t.datetime "created_at", null: false
    t.string "file_name"
    t.jsonb "metadata", default: {}, null: false
    t.bigint "organization_id", null: false
    t.string "source_type", default: "pasted_text", null: false
    t.string "status", default: "ingested", null: false
    t.string "title", null: false
    t.datetime "updated_at", null: false
    t.bigint "user_id", null: false
    t.index ["metadata"], name: "index_training_documents_on_metadata", using: :gin
    t.index ["organization_id", "status"], name: "index_training_documents_on_organization_id_and_status"
    t.index ["organization_id", "user_id", "created_at"], name: "idx_on_organization_id_user_id_created_at_9dd21899c0"
    t.index ["organization_id"], name: "index_training_documents_on_organization_id"
    t.index ["user_id"], name: "index_training_documents_on_user_id"
  end

  create_table "training_vault_documents", force: :cascade do |t|
    t.datetime "approved_at"
    t.bigint "approved_by_id"
    t.datetime "archived_at"
    t.text "body", null: false
    t.string "body_sha256", null: false
    t.integer "byte_size", default: 0, null: false
    t.string "content_type"
    t.datetime "created_at", null: false
    t.string "file_name"
    t.string "folder_path"
    t.datetime "indexed_at"
    t.jsonb "metadata", default: {}, null: false
    t.bigint "organization_id", null: false
    t.string "source_type", default: "vault_upload", null: false
    t.string "status", default: "review", null: false
    t.string "title", null: false
    t.datetime "updated_at", null: false
    t.bigint "user_id", null: false
    t.index ["approved_by_id"], name: "index_training_vault_documents_on_approved_by_id"
    t.index ["metadata"], name: "index_training_vault_documents_on_metadata", using: :gin
    t.index ["organization_id", "body_sha256"], name: "idx_training_vault_documents_org_digest"
    t.index ["organization_id", "status"], name: "index_training_vault_documents_on_organization_id_and_status"
    t.index ["organization_id"], name: "index_training_vault_documents_on_organization_id"
    t.index ["user_id"], name: "index_training_vault_documents_on_user_id"
  end

  create_table "users", force: :cascade do |t|
    t.string "aircall_external_key"
    t.string "aircall_number_id"
    t.string "aircall_user_id"
    t.datetime "confirmation_sent_at"
    t.datetime "confirmed_at"
    t.datetime "created_at", null: false
    t.string "email_address", null: false
    t.string "name"
    t.string "password_digest", null: false
    t.string "phone_number"
    t.string "twilio_from_number"
    t.string "twilio_messaging_service_sid"
    t.datetime "updated_at", null: false
    t.index ["aircall_external_key"], name: "index_users_on_aircall_external_key"
    t.index ["email_address"], name: "index_users_on_email_address", unique: true
    t.index ["twilio_from_number"], name: "index_users_on_twilio_from_number"
    t.index ["twilio_messaging_service_sid"], name: "index_users_on_twilio_messaging_service_sid"
  end

  create_table "weather_lead_signals", force: :cascade do |t|
    t.jsonb "affected_postal_codes", default: [], null: false
    t.jsonb "affected_states", default: [], null: false
    t.string "area_desc"
    t.string "certainty"
    t.datetime "created_at", null: false
    t.text "description"
    t.string "event", null: false
    t.datetime "expires_at"
    t.string "headline"
    t.jsonb "metadata", default: {}, null: false
    t.bigint "organization_id", null: false
    t.jsonb "raw_payload", default: {}, null: false
    t.string "severity"
    t.string "signal_type", default: "alert", null: false
    t.string "source", default: "weather.gov", null: false
    t.string "source_uid", null: false
    t.datetime "started_at"
    t.string "status", default: "active", null: false
    t.datetime "updated_at", null: false
    t.string "urgency"
    t.index ["affected_postal_codes"], name: "index_weather_lead_signals_on_affected_postal_codes", using: :gin
    t.index ["affected_states"], name: "index_weather_lead_signals_on_affected_states", using: :gin
    t.index ["metadata"], name: "index_weather_lead_signals_on_metadata", using: :gin
    t.index ["organization_id", "signal_type", "status"], name: "idx_weather_signals_type_status"
    t.index ["organization_id", "source", "source_uid"], name: "idx_weather_signals_unique_source", unique: true
    t.index ["organization_id", "status", "expires_at"], name: "idx_weather_signals_status_expiry"
    t.index ["organization_id"], name: "index_weather_lead_signals_on_organization_id"
  end

  create_table "weather_zip_crosswalks", force: :cascade do |t|
    t.decimal "bus_ratio", precision: 12, scale: 8
    t.string "county_fips", null: false
    t.datetime "created_at", null: false
    t.jsonb "metadata", default: {}, null: false
    t.decimal "oth_ratio", precision: 12, scale: 8
    t.string "postal_code", null: false
    t.string "preferred_city"
    t.decimal "res_ratio", precision: 12, scale: 8
    t.string "source", default: "hud_usps", null: false
    t.string "source_version", default: "unknown", null: false
    t.string "state"
    t.decimal "total_ratio", precision: 12, scale: 8
    t.datetime "updated_at", null: false
    t.index ["county_fips", "postal_code"], name: "idx_weather_zip_crosswalks_county_zip"
    t.index ["metadata"], name: "index_weather_zip_crosswalks_on_metadata", using: :gin
    t.index ["postal_code"], name: "index_weather_zip_crosswalks_on_postal_code"
    t.index ["source", "source_version", "postal_code", "county_fips"], name: "idx_weather_zip_crosswalks_unique_source_version", unique: true
    t.index ["state", "postal_code"], name: "idx_weather_zip_crosswalks_state_zip"
  end

  add_foreign_key "active_storage_attachments", "active_storage_blobs", column: "blob_id"
  add_foreign_key "active_storage_variant_records", "active_storage_blobs", column: "blob_id"
  add_foreign_key "autos_embedding_chunks", "organizations"
  add_foreign_key "autos_questions", "organizations"
  add_foreign_key "autos_questions", "users"
  add_foreign_key "build_requests", "organizations"
  add_foreign_key "build_requests", "users"
  add_foreign_key "canva_connections", "organizations"
  add_foreign_key "canva_connections", "users"
  add_foreign_key "comms_board_rollups", "crm_record_artifacts", name: "comms_board_rollups_crm_record_artifact_id_fkey", on_delete: :cascade
  add_foreign_key "crm_address_records", "crm_records"
  add_foreign_key "crm_address_records", "organizations"
  add_foreign_key "crm_address_records", "playbook_calls"
  add_foreign_key "crm_associations", "crm_records", column: "from_record_id"
  add_foreign_key "crm_associations", "crm_records", column: "to_record_id"
  add_foreign_key "crm_associations", "organizations"
  add_foreign_key "crm_property_definitions", "organizations"
  add_foreign_key "crm_record_artifacts", "crm_records"
  add_foreign_key "crm_record_artifacts", "organizations"
  add_foreign_key "crm_record_artifacts", "users"
  add_foreign_key "crm_records", "organizations"
  add_foreign_key "crm_records", "users", column: "owner_id"
  add_foreign_key "crm_records", "users", column: "priority_marked_by_id"
  add_foreign_key "design_orders", "design_reports"
  add_foreign_key "design_orders", "organizations"
  add_foreign_key "design_orders", "users"
  add_foreign_key "design_reports", "organizations"
  add_foreign_key "design_reports", "users"
  add_foreign_key "wizwiki_automation_runs", "organizations"
  add_foreign_key "duplicate_candidates", "crm_records"
  add_foreign_key "duplicate_candidates", "crm_records", column: "duplicate_record_id"
  add_foreign_key "duplicate_candidates", "organizations"
  add_foreign_key "employee_profiles", "organizations"
  add_foreign_key "employee_profiles", "users"
  add_foreign_key "fathom_calls", "organizations"
  add_foreign_key "ingestion_events", "crm_records"
  add_foreign_key "ingestion_events", "organizations"
  add_foreign_key "kalshi_weather_prediction_snapshots", "kalshi_weather_predictions"
  add_foreign_key "kalshi_weather_prediction_snapshots", "organizations"
  add_foreign_key "kalshi_weather_predictions", "organizations"
  add_foreign_key "kalshi_weather_wagers", "kalshi_weather_predictions"
  add_foreign_key "kalshi_weather_wagers", "organizations"
  add_foreign_key "memberships", "organizations"
  add_foreign_key "memberships", "users"
  add_foreign_key "playbook_calls", "crm_records"
  add_foreign_key "playbook_calls", "organizations"
  add_foreign_key "quick_cart_orders", "crm_records"
  add_foreign_key "quick_cart_orders", "organizations"
  add_foreign_key "sessions", "users"
  add_foreign_key "training_documents", "organizations"
  add_foreign_key "training_documents", "users"
  add_foreign_key "training_vault_documents", "organizations"
  add_foreign_key "training_vault_documents", "users"
  add_foreign_key "training_vault_documents", "users", column: "approved_by_id"
  add_foreign_key "weather_lead_signals", "organizations"
end
