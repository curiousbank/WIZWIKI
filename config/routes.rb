Rails.application.routes.draw do
  get "access", to: "sessions#new", as: :access
  resource :site_gate, only: [:new, :create, :destroy]
  resource :registration, only: [:new, :create]
  get "confirmations/:token", to: "confirmations#show", as: :confirmation
  resource :session
  post "quick_cart", to: "quick_carts#create", as: :quick_cart
  resources :passwords, param: :token

  get "dashboard", to: "dashboard#index", as: :dashboard
  resource :profile, only: [:edit, :update]
  get "map", to: "data_maps#show", as: :data_map
  get "weather", to: "weather#index", as: :weather
  patch "weather/risk", to: "weather#update_risk", as: :update_weather_risk
  post "weather/sniff", to: "weather#sniff", as: :sniff_weather
  post "weather/buy", to: "weather#manual_buy", as: :buy_weather
  get "canva/connect", to: "canva/oauth#connect", as: :connect_canva
  get "canva/oauth/callback", to: "canva/oauth#callback", as: :canva_oauth_callback
  get "internal/pipeline_status", to: "pipeline_status#show", as: :internal_pipeline_status
  get "autos/brain_power", to: "brain_power#show", as: :autos_brain_power
  get "autos_worker/status", to: "autos_worker#status", as: :autos_worker_status
  get "autos_worker/next", to: "autos_worker#next", as: :autos_worker_next
  get "autos_worker/embeddings/status", to: "autos_worker#embedding_status", as: :autos_worker_embedding_status
  post "autos_worker/embeddings/next", to: "autos_worker#next_embedding", as: :autos_worker_next_embedding
  post "autos_worker/embeddings/search", to: "autos_worker#search_embeddings", as: :autos_worker_search_embeddings
  post "autos_worker/embeddings/:id/complete", to: "autos_worker#complete_embedding", as: :autos_worker_complete_embedding
  post "autos_worker/embeddings/:id/fail", to: "autos_worker#fail_embedding", as: :autos_worker_fail_embedding
  post "autos_worker/messages/:id/complete", to: "autos_worker#complete", as: :autos_worker_complete
  post "autos_worker/messages/:id/fail", to: "autos_worker#fail", as: :autos_worker_fail
  get "wizwiki_worker/report_status", to: "wizwiki_worker#report_status", as: :wizwiki_worker_report_status
  get "wizwiki_worker/reports/recent", to: "wizwiki_worker#recent_reports", as: :wizwiki_worker_recent_reports
  get "wizwiki_worker/agency_logo", to: "wizwiki_worker#agency_logo", as: :wizwiki_worker_agency_logo
  post "wizwiki_worker/reports/next", to: "wizwiki_worker#next_report", as: :wizwiki_worker_next_report
  get "wizwiki_worker/reports/:id/logo", to: "wizwiki_worker#logo", as: :wizwiki_worker_report_logo
  get "wizwiki_worker/reports/:id/media/:attachment_id", to: "wizwiki_worker#media", as: :wizwiki_worker_report_media
  post "wizwiki_worker/reports/:id/heartbeat", to: "wizwiki_worker#heartbeat_report", as: :wizwiki_worker_report_heartbeat
  post "wizwiki_worker/reports/:id/complete", to: "wizwiki_worker#complete_report", as: :wizwiki_worker_complete_report
  post "wizwiki_worker/reports/:id/fail", to: "wizwiki_worker#fail_report", as: :wizwiki_worker_fail_report
  get "approve", to: "approvals#index", as: :approve
  patch "approve/build_requests/:id", to: "approvals#update_build_request", as: :approve_build_request
  get "approve/users/:id/edit", to: "approvals#edit_user", as: :edit_approve_user
  patch "approve/users/:id", to: "approvals#update_user", as: :approve_user
  post "approve/users/:id/send_password_reset", to: "approvals#send_password_reset", as: :send_password_reset_approve_user
  get "leads", to: redirect("/leads/comms"), as: :deal_queue
  get "leads/sync/status", to: "deal_queues#sync_status", as: :sync_deal_queue_status
  post "leads/sync", to: "deal_queues#sync", as: :sync_deal_queue
  post "leads/weather/sync", to: "deal_queues#sync_weather", as: :sync_weather_deal_queue
  post "leads/comms/run_all", to: "deal_queues#run_all_comms", as: :run_all_deal_comms
  get "leads/comms", to: "comms_commands#index", as: :comms_command
  get "leads/comms/version", to: "comms_commands#board_version", as: :comms_board_version
  get "leads/copmms", to: redirect("/leads/comms")
  post "leads/comms/manual", to: "comms_commands#create_manual", as: :create_manual_comms
  post "leads/comms/import", to: "comms_commands#import_csv", as: :import_comms_csv
  patch "leads/comms/sms-language", to: "comms_commands#update_sms_language_settings", as: :update_comms_sms_language_settings
  patch "leads/comms/follow-up", to: "comms_commands#update_follow_up_settings", as: :update_comms_follow_up_settings
  patch "leads/comms/batch-templates", to: "comms_commands#update_batch_templates", as: :update_comms_batch_templates
  post "leads/comms/hubspot/sample_owner", to: "comms_commands#sync_owner_owner", as: :sync_owner_comms
  post "leads/comms/weather/storm-watch", to: "comms_commands#sync_storm_watch", as: :sync_storm_watch_comms
  post "leads/comms/autopilot/run_all", to: "comms_commands#run_all_autopilot", as: :run_all_comms_autopilot
  post "leads/comms/copilot/run_all", to: "comms_commands#run_all_copilot", as: :run_all_comms_copilot
  post "leads/comms/claim_visible", to: "comms_commands#claim_visible", as: :claim_visible_comms
  delete "leads/comms", to: "comms_commands#destroy_all", as: :delete_all_comms_commands
  delete "leads/comms/:id", to: "comms_commands#destroy", as: :delete_comms_command
  patch "leads/comms/:id/am-support", to: "comms_commands#send_to_am", as: :send_to_am_comms
  patch "leads/comms/:id/board-state", to: "comms_commands#update_board_state", as: :update_comms_board_state
  patch "leads/comms/:id/autopilot", to: "comms_commands#toggle_autopilot", as: :toggle_comms_autopilot
  patch "leads/comms/:id/sms/writer-model", to: "comms_commands#update_sms_writer_model", as: :update_comms_sms_writer_model
  patch "leads/comms/:id/sms/rag-profile", to: "comms_commands#update_rag_profile", as: :update_comms_rag_profile
  get "leads/comms/:id/live", to: "comms_commands#show_stage", as: :live_comms_command
  post "leads/comms/:id/sms/copilot", to: "comms_commands#copilot_sms", as: :copilot_comms_sms
  post "leads/comms/:id/sms/reset", to: "comms_commands#reset_sms_conversation", as: :reset_comms_sms
  post "leads/comms/:id/sms/draft", to: "comms_commands#draft_sms", as: :draft_comms_sms
  post "leads/comms/:id/sms", to: "comms_commands#send_sms", as: :send_comms_sms
  post "leads/comms/:id/email/draft", to: "comms_commands#draft_email", as: :draft_comms_email
  post "leads/comms/:id/email", to: "comms_commands#send_email", as: :send_comms_email
  get "comms/location/:token", to: "comms_locations#show", as: :comms_location
  post "comms/location/:token", to: "comms_locations#create"
  post "webhooks/twilio/sms", to: "twilio_webhooks#sms", as: :twilio_sms_webhook
  post "webhooks/heymarket/sms", to: "twilio_webhooks#heymarket", as: :heymarket_sms_webhook
  post "leads/:id/claim", to: "deal_queues#claim", as: :claim_deal
  patch "leads/:id/priority", to: "deal_queues#update_priority", as: :update_deal_priority
  get "leads/:id/reports/status", to: "deal_queues#report_status", as: :deal_report_status
  post "leads/:id/reports", to: "deal_queues#queue_report", as: :queue_deal_report
  delete "leads/reports/:id", to: "deal_queues#remove_report_from_queue", as: :remove_deal_report_from_queue
  post "leads/:id/media", to: "deal_queues#upload_media", as: :upload_deal_media
  delete "leads/:id/media/:attachment_id", to: "deal_queues#destroy_media", as: :destroy_deal_media
  get "leads/reports/:id/preview", to: "deal_queues#preview_report", as: :preview_deal_report
  get "leads/reports/:id/download", to: "deal_queues#download_report", as: :download_deal_report
  get "leads/reports/:id/canva-kit", to: "deal_queues#download_canva_kit", as: :download_deal_report_canva_kit
  get "leads/reports/:id/canva-output", to: "deal_queues#download_canva_output", as: :download_deal_report_canva_output
  get "leads/reports/:id/canva-pdf", to: "deal_queues#download_canva_pdf", as: :download_deal_report_canva_pdf
  get "leads/reports/:id/canva-export/:filename", to: "deal_queues#download_canva_export", as: :download_deal_report_canva_export, constraints: { filename: /[^\/]+/ }
  post "leads/reports/:id/canva-build", to: "deal_queues#build_canva_output", as: :build_deal_report_canva_output
  post "leads/reports/:id/comms/prepare", to: "deal_queues#prepare_report_comms", as: :prepare_deal_report_comms
  post "leads/comms/:id/run", to: "deal_queues#run_comms_stage", as: :run_deal_comms
  get "deals", to: redirect("/leads/comms")
  get "deals/sync/status", to: "deal_queues#sync_status"
  post "deals/sync", to: "deal_queues#sync"
  post "deals/weather/sync", to: "deal_queues#sync_weather"
  post "deals/comms/run_all", to: "deal_queues#run_all_comms"
  get "deals/comms", to: redirect("/leads/comms")
  post "deals/:id/claim", to: "deal_queues#claim"
  patch "deals/:id/priority", to: "deal_queues#update_priority"
  get "deals/:id/reports/status", to: "deal_queues#report_status"
  post "deals/:id/reports", to: "deal_queues#queue_report"
  delete "deals/reports/:id", to: "deal_queues#remove_report_from_queue"
  post "deals/:id/media", to: "deal_queues#upload_media"
  delete "deals/:id/media/:attachment_id", to: "deal_queues#destroy_media"
  get "deals/reports/:id/preview", to: "deal_queues#preview_report"
  get "deals/reports/:id/download", to: "deal_queues#download_report"
  get "deals/reports/:id/canva-kit", to: "deal_queues#download_canva_kit"
  get "deals/reports/:id/canva-output", to: "deal_queues#download_canva_output"
  get "deals/reports/:id/canva-pdf", to: "deal_queues#download_canva_pdf"
  get "deals/reports/:id/canva-export/:filename", to: "deal_queues#download_canva_export", constraints: { filename: /[^\/]+/ }
  post "deals/reports/:id/canva-build", to: "deal_queues#build_canva_output"
  post "deals/reports/:id/comms/prepare", to: "deal_queues#prepare_report_comms"
  post "deals/comms/:id/run", to: "deal_queues#run_comms_stage"
  resources :design_reports, path: "designs", only: [:index, :show, :create]
  resources :design_orders, path: "design-orders", only: [:show]
  get "build", to: "builds#index", as: :build
  post "build", to: "builds#create"
  get "ask", to: "asks#index", as: :ask
  get "ask/questions", to: "asks#questions", as: :ask_questions
  get "ask/autopilot-test", to: "asks#show_autopilot_test", as: :ask_autopilot_test
  post "ask/autopilot-test", to: "asks#start_autopilot_test", as: :start_ask_autopilot_test
  post "ask/autopilot-test/reply", to: "asks#reply_autopilot_test", as: :reply_ask_autopilot_test
  post "ask/autopilot-test/dojo", to: "asks#start_recursive_dojo", as: :recursive_dojo_ask_autopilot_test
  delete "ask/autopilot-test", to: "asks#clear_autopilot_test", as: :clear_ask_autopilot_test
  post "ask/questions/:id/cancel", to: "asks#cancel", as: :cancel_ask_question
  post "ask", to: "asks#create"
  get "train", to: "training_documents#index", as: :train
  get "train/fine-training", to: "training_documents#fine_training", as: :fine_training
  post "train/playbooks/sync", to: "training_documents#sync_playbooks", as: :sync_playbooks
  post "train/fathom/sync", to: "training_documents#sync_fathom", as: :sync_fathom
  post "train/memory/enqueue", to: "training_documents#enqueue_memory", as: :enqueue_memory
  post "train/fine-training/embed", to: "training_documents#enqueue_fine_training", as: :enqueue_fine_training
  get "train/adaptive-learning/feed", to: "training_documents#adaptive_learning_feed", as: :adaptive_learning_feed
  post "train/adaptive-learning/scan", to: "training_documents#scan_adaptive_learning", as: :scan_adaptive_learning
  post "train/adaptive-learning/:id/approve", to: "training_documents#approve_adaptive_learning", as: :approve_adaptive_learning
  post "train/adaptive-learning/:id/reject", to: "training_documents#reject_adaptive_learning", as: :reject_adaptive_learning
  post "train/adaptive-learning/:id/revoke", to: "training_documents#revoke_adaptive_learning", as: :revoke_adaptive_learning
  patch "train/documents/:id", to: "training_documents#update", as: :training_document
  resources :training_vault_documents, path: "train/vault", only: [:create] do
    member do
      post :approve
      patch :archive
    end
  end
  get "team", to: "teams#index", as: :team
  get "teanm", to: redirect("/team")
  post "train", to: "training_documents#create"

  namespace :crm do
    root "records#index"
    resources :records
    resources :property_definitions
    resources :duplicate_candidates, only: [:index, :update]
  end

  # Reveal health status on /up that returns 200 if the app boots with no exceptions, otherwise 500.
  # Can be used by load balancers and uptime monitors to verify that the app is live.
  get "up" => "rails/health#show", as: :rails_health_check

  # Render dynamic PWA files from app/views/pwa/* (remember to link manifest in application.html.erb)
  # get "manifest" => "rails/pwa#manifest", as: :pwa_manifest
  # get "service-worker" => "rails/pwa#service_worker", as: :pwa_service_worker

  root "landing#index"
end
