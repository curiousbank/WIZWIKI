require "erb"
require "yaml"

module WizwikiSettings
  module_function

REPORT_LOCAL_MODEL_OPTIONS = [
  ["Qwen 3 8B // fast lab option", "qwen3:8b"],
  ["Qwen 3.5 9B MLX // compact Apple writer", "qwen3.5:9b-mlx"],
  ["★ Qwen 3 30B // default local writer", "qwen3:30b"],
  ["Qwen 3.6 35B MLX // heaviest Apple test", "qwen3.6:35b-mlx"]
].freeze

REPORT_EMBEDDER_MODEL_OPTIONS = [
  ["★ Qwen Embed 8B Q4 // default deep context", "qwen3-embedding:8b-q4_K_M"],
  ["Qwen Embed 4B // balanced fallback context", "qwen3-embedding:4b"]
].freeze

CHALLENGER_MODEL_OPTIONS = [
  ["★ Qwen 3 4B // default fastest challenger", "qwen3:4b"],
  ["Qwen 3 8B // fast challenger", "qwen3:8b"],
  ["Qwen 3 14B // deeper challenger", "qwen3:14b"],
  ["Mistral Small 24B // challenger judge", "mistral-small:24b"],
  ["Gemma 3 27B // challenger judge", "gemma3:27b"]
].freeze

SMS_WRITER_MODEL_OPTIONS = [
  ["Qwen 3 4B // fastest SMS writer", "qwen3:4b"],
  ["Qwen 3 8B // fast SMS writer", "qwen3:8b"],
  ["Qwen 3 14B // stronger SMS writer", "qwen3:14b"],
  ["LOCAL // Alice Qwen 30B", "qwen3:30b"],
  ["WARP // rented GPU SMS", "nvidia:warp"],
  ["NEMOTRON // NVIDIA hosted SMS", "nvidia:nemotron"],
  ["OpenAI // cloud SMS", "openai:gpt"]
].freeze

REPORT_LANE_OPTIONS = [
  {
    value: "default_qwen3_30b_8b",
    label: "★ DEFAULT // RAG 8B + Qwen 3 30B",
    report_local_model: "qwen3:30b",
    report_model_ladder: ["qwen3:30b"],
    report_embedder_model: "qwen3-embedding:8b-q4_K_M",
    description: "Default deep retrieval. 8B Q4 retrieves HubSpot/training context; Qwen 3 30B writes; repair runs only when validation asks."
  },

  {
    value: "reliable_30b_4b",
    label: "RELIABLE // RAG 4B + Qwen 3 30B",
    report_local_model: "qwen3:30b",
    report_model_ladder: ["qwen3:30b"],
    report_embedder_model: "qwen3-embedding:4b",
    description: "Same balanced retrieval with a heavier local writer for richer copy tests."
  },
  {
    value: "quick_30b_06",
    label: "QUICK // RAG 0.6B + Qwen 3 30B",
    report_local_model: "qwen3:30b",
    report_model_ladder: ["qwen3:30b"],
    report_embedder_model: "qwen3-embedding:0.6b",
    description: "Fastest retrieval lane with 30B writing. Good for quick smoke tests."
  },
  {
    value: "deep_8b_30b_8b",
    label: "DEEP // RAG 8B + Qwen 3 8B -> 30B",
    report_local_model: "qwen3:30b",
    report_model_ladder: ["qwen3:8b", "qwen3:30b"],
    report_embedder_model: "qwen3-embedding:8b-q4_K_M",
    description: "Deep retrieval and staged writing. Best for heavier account context tests."
  }
].freeze

  def application_config
    @application_config ||= begin
      path = Rails.root.join("config/application.yml")
      if path.exist?
        YAML.safe_load(ERB.new(path.read).result, aliases: true) || {}
      else
        {}
      end
    rescue StandardError => error
      Rails.logger.warn("WizwikiSettings config load failed: #{error.class}")
      {}
    end
  end

  def environment_config
    config = application_config
    config.fetch(Rails.env, config).to_h
  end


  def hubspot
    environment_config.fetch("hubspot", {}).to_h
  end

  def hubspot_key
    ENV["HUBSPOT_KEY"].presence || hubspot["api_key"].presence
  end

  def hubspot_configured?
    credential_present?(hubspot_key)
  end

  def fathom
    environment_config.fetch("fathom", {}).to_h
  end

  def fathom_api_key
    ENV["FATHOM_API_KEY"].presence || fathom["api_key"].presence
  end

  def fathom_webhook_secret
    ENV["FATHOM_WEBHOOK_SECRET"].presence || fathom["webhook_secret"].presence
  end

  def fathom_base_url
    ENV["FATHOM_BASE_URL"].presence || fathom["base_url"].presence || Fathom::Client::DEFAULT_BASE_URL
  rescue NameError
    ENV["FATHOM_BASE_URL"].presence || fathom["base_url"].presence || "https://api.fathom.ai/external/v1"
  end

  def fathom_configured?
    credential_present?(fathom_api_key)
  end

  def backblaze
    environment_config.fetch("backblaze", {}).to_h
  end

  def backblaze_key_id
    ENV["WIZWIKI_B2_KEY_ID"].presence || ENV["B2_KEY_ID"].presence || backblaze["key_id"].presence
  end

  def backblaze_application_key
    ENV["WIZWIKI_B2_APPLICATION_KEY"].presence || ENV["B2_APPLICATION_KEY"].presence || backblaze["application_key"].presence
  end

  def backblaze_bucket
    ENV["WIZWIKI_B2_BUCKET"].presence || ENV["B2_BUCKET"].presence || backblaze["bucket"].presence
  end

  def backblaze_rclone_remote
    ENV["WIZWIKI_B2_RCLONE_REMOTE"].presence || ENV["B2_RCLONE_REMOTE"].presence || backblaze["rclone_remote"].presence
  end

  def backblaze_public_base_url
    ENV["WIZWIKI_B2_PUBLIC_BASE_URL"].presence || ENV["B2_PUBLIC_BASE_URL"].presence || backblaze["public_base_url"].presence
  end

  def backblaze_report_prefix
    value = ENV["WIZWIKI_B2_REPORT_PREFIX"].presence || backblaze["report_prefix"].presence || "wizwiki/deal_reports"
    value.to_s.strip.gsub(%r{/+}, "/").sub(%r{\A/+}, "").sub(%r{/+\z}, "")
  end

  def backblaze_configured?
    direct_b2 = credential_present?(backblaze_key_id) && credential_present?(backblaze_application_key) && credential_present?(backblaze_bucket)
    rclone_b2 = credential_present?(backblaze_rclone_remote) && credential_present?(backblaze_bucket)
    direct_b2 || rclone_b2
  end


  def cloudinary
    environment_config.fetch("cloudinary", {}).to_h
  end

  def cloudinary_cloud_name
    ENV["CLOUDINARY_CLOUD_NAME"].presence || cloudinary["cloud_name"].presence
  end

  def cloudinary_api_key
    ENV["CLOUDINARY_API_KEY"].presence || cloudinary["api_key"].presence
  end

  def cloudinary_api_secret
    ENV["CLOUDINARY_API_SECRET"].presence || cloudinary["api_secret"].presence
  end

  def cloudinary_folder
    ENV["WIZWIKI_CLOUDINARY_FOLDER"].presence || cloudinary["folder"].presence || "wizwiki"
  end

  def cloudinary_configured?
    credential_present?(cloudinary_cloud_name) && credential_present?(cloudinary_api_key) && credential_present?(cloudinary_api_secret)
  end

  def openai
    environment_config.fetch("openai", {}).to_h
  end

  def openai_api_key
    ENV["OPENAI_API_KEY"].presence || openai["api_key"].presence
  end

  def openai_model
    ENV["OPENAI_MODEL"].presence || openai["model"].presence || "gpt-5.4"
  end

  def openai_reasoning_effort
    raw = ENV["OPENAI_REASONING_EFFORT"].presence || openai["reasoning_effort"].presence
    normalize_openai_reasoning_effort(raw)
  end

  def openai_configured?
    credential_present?(openai_api_key)
  end

  def ai_provider
    (ENV["WIZWIKI_AI_PROVIDER"].presence || ENV["AUTOS_AI_PROVIDER"].presence || "qwen").to_s.strip.downcase.tr("-", "_")
  end

  def qwen_only?
    truthy?(ENV["WIZWIKI_QWEN_ONLY"]) || %w[qwen qwen_only local local_qwen qwen_local].include?(ai_provider)
  end

  def openai_runtime_enabled?
    !qwen_only? && openai_configured?
  end

def qwen_model
  normalize_report_local_model_alias(ENV["WIZWIKI_QWEN_MODEL"].presence || ENV["QWEN_MODEL"].presence || "qwen3:30b")
end

def active_ai_provider
    qwen_only? ? "qwen/local" : "openai"
  end

  def active_ai_model
    qwen_only? ? qwen_model : openai_model
  end

  def openai_max_context_chars
    (ENV["OPENAI_MAX_CONTEXT_CHARS"].presence || openai["max_context_chars"].presence || 14_000).to_i.clamp(2_000, 80_000)
  end

  def openai_max_output_tokens
    (ENV["OPENAI_MAX_OUTPUT_TOKENS"].presence || openai["max_output_tokens"].presence || 1_600).to_i.clamp(300, 4_000)
  end

  def openai_daily_token_budget
    (ENV["OPENAI_DAILY_TOKEN_BUDGET"].presence || openai["daily_token_budget"].presence || 100_000).to_i.clamp(1_000, 100_000_000)
  end
def canva
  environment_config.fetch("canva", {}).to_h
end

def canva_client_id
  ENV["CANVA_CLIENT_ID"].presence || canva["client_id"].presence
end

def canva_client_secret
  ENV["CANVA_CLIENT_SECRET"].presence || canva["client_secret"].presence
end

def canva_redirect_uri
  ENV["CANVA_REDIRECT_URI"].presence || canva["redirect_uri"].presence || "https://wizwiki.local/canva/oauth/callback"
end

def canva_scopes
  ENV["CANVA_SCOPES"].presence || canva["scopes"].presence || "design:content:write design:content:read design:meta:read brandtemplate:meta:read brandtemplate:content:read asset:read asset:write folder:read folder:write"
end

def canva_brand_template_id
  ENV["CANVA_BRAND_TEMPLATE_ID"].presence || canva["brand_template_id"].presence
end

def canva_export_formats
  raw = ENV["CANVA_EXPORT_FORMATS"].presence || canva["export_formats"].presence || "pdf,pptx"
  Array(raw.is_a?(String) ? raw.split(/[ ,]+/) : raw).map(&:to_s).map(&:strip).reject(&:blank?).map(&:downcase).uniq
end

def canva_poll_seconds
  (ENV["CANVA_POLL_SECONDS"].presence || canva["poll_seconds"].presence || 45).to_i.clamp(6, 180)
end

def canva_configured?
  credential_present?(canva_client_id) && credential_present?(canva_client_secret) && credential_present?(canva_redirect_uri)
end

def canva_autofill_ready?
  canva_configured? && credential_present?(canva_brand_template_id)
end

def canva_auto_build_enabled?
  !!ActiveModel::Type::Boolean.new.cast(ENV["CANVA_AUTO_BUILD_ENABLED"].presence || canva["auto_build_enabled"])
end


  def square
    environment_config.fetch("square", {}).to_h
  end

  def square_mode
    ENV["SQUARE_ENV"].presence || square["mode"].presence || "production"
  end

  def square_application_id
    ENV["SQUARE_APPLICATION_ID"].presence || square["application_id"].presence
  end

  def square_location_id
    ENV["SQUARE_LOCATION_ID"].presence || square["location_id"].presence
  end

  def square_access_token
    ENV["SQUARE_ACCESS_TOKEN"].presence || ENV["SQUARE_TOKEN"].presence || square["access_token"].presence
  end

  def square_currency
    ENV["SQUARE_CURRENCY"].presence || square["currency"].presence || "USD"
  end

  def campaign_url
    ENV["WIZWIKI_CAMPAIGN_URL"].presence || square["campaign_url"].presence || "https://app.example.invalid"
  end

  def square_frontend_configured?
    credential_present?(square_application_id) && credential_present?(square_location_id)
  end

  def square_server_configured?
    credential_present?(square_access_token) && credential_present?(square_location_id)
  end

def square_checkout_configured?(package, production_speed: "standard")
  square_frontend_configured? && square_server_configured? && square_package_amount_cents(package, production_speed: production_speed).positive?
end

def square_package_amount_cents(package, production_speed: "standard")
  key = package.to_s.upcase
  env_value = ENV["WIZWIKI_QUICK_CART_#{key}_AMOUNT_CENTS"]
  value = env_value.presence || package_config(key)["amount_cents"]
  base_amount = value.to_i
  return base_amount unless production_speed.to_s == "skip_line"

  (base_amount * square_skip_line_multiplier).ceil
end

def square_skip_line_multiplier
  raw = ENV["WIZWIKI_SKIP_LINE_MULTIPLIER"].presence || square["skip_line_multiplier"].presence || 1.5
  raw.to_f.clamp(1.0, 10.0)
end

  def square_package_label(package)
    key = package.to_s.upcase
    package_config(key)["label"].presence || key.titleize
  end

def square_package_price_label(package, production_speed: "standard")
  amount_cents = square_package_amount_cents(package, production_speed: production_speed)
  return "price set in config" unless amount_cents.positive?

  ActionController::Base.helpers.number_to_currency(amount_cents / 100.0)
end

  def autos_worker_token
    ENV["WIZWIKI_AUTOS_WORKER_TOKEN"].presence || ENV["AUTOS_WORKER_TOKEN"].presence
  end


  def wizwiki_report_worker_token
    ENV["WIZWIKI_REPORT_WORKER_TOKEN"].presence || autos_worker_token
  end

  def wizwiki_report_worker_configured?
    credential_present?(wizwiki_report_worker_token)
  end

  def wizwiki_report_worker_enabled?
    wizwiki_report_worker_configured? && truthy?(ENV["WIZWIKI_REPORT_WORKER_ENABLED"].presence || "true")
  end

  def autos_local_worker_enabled?
    qwen_only? || truthy?(ENV["WIZWIKI_AUTOS_LOCAL_WORKER_ENABLED"].presence || ENV["AUTOS_LOCAL_WORKER_ENABLED"])
  end

  def autos_local_model
    return qwen_model if qwen_only?

    ENV["WIZWIKI_AUTOS_LOCAL_MODEL"].presence || ENV["AUTOS_LOCAL_MODEL"].presence || "qwen3:30b"
  end

  def wizwiki_report_provider
    active_ai_provider
  end

  def wizwiki_report_target_model
    active_ai_model
  end

def report_local_model_options
  configured = qwen_model.to_s.strip
  allowed = REPORT_LOCAL_MODEL_OPTIONS.map(&:last)
  options = REPORT_LOCAL_MODEL_OPTIONS.dup + configured_report_local_model_options
  options = options.map { |label, model| [report_model_display_label(normalize_report_local_model_alias(model)).presence || label, normalize_report_local_model_alias(model)] }
    .select { |_label, model| allowed.include?(model) }
    .uniq { |_label, model| model }
  if configured.present? && allowed.include?(configured) && options.none? { |_label, model| model == configured }
    options.unshift([report_model_display_label(configured), configured])
  end
  options
end

def configured_report_local_model_options
  parse_report_local_model_options(
    ENV["WIZWIKI_REPORT_LOCAL_MODELS"].presence || ENV["ALICE_REPORT_MODELS"].presence
  )
end

def parse_report_local_model_options(value)
  value.to_s.split(/[;,\n]/).filter_map do |entry|
    raw = entry.to_s.strip
    next if raw.blank?

    label, model = raw.split(/\s*(?:=>|=|\|)\s*/, 2)
    if model.blank?
      model = label
      label = report_model_display_label(model)
    end

    model = model.to_s.strip
    label = label.to_s.strip
    next if model.blank?

    [label.presence || report_model_display_label(model), model]
  end
end

def report_model_display_label(model)
  cleaned = normalize_report_local_model_alias(model)
  case cleaned
  when "qwen3.5:9b" then "Qwen 3.5 9B MLX // compact Apple writer"
  when "qwen3:8b" then "Qwen 3 8B // fast lab option"
  when "qwen3:30b" then "★ Qwen 3 30B // default local writer"
  when "qwen3.5:9b-mlx" then "Qwen 3.5 9B MLX // compact Apple writer"
  when "qwen3.6:27b-mlx" then "Qwen 3.6 27B MLX // larger Apple test"
  when "qwen3.6:35b-mlx" then "Qwen 3.6 35B MLX // heaviest Apple test"
  else "Alice local // #{cleaned}"
  end
end

def report_local_model_label(model)
  selected = normalize_report_local_model_alias(model)
  report_local_model_options.find { |_label, value| value == selected }&.first || report_model_display_label(selected)
end

def normalize_report_local_model(value)
  allowed_models = report_local_model_options.map(&:last)
  selected = normalize_report_local_model_alias(value)
  allowed_models.include?(selected) ? selected : allowed_models.first
end

def normalize_report_local_model_alias(value)
  cleaned = value.to_s.strip
  case cleaned
  when "qwen3.5:9b", "qwen3.5:9b-ollama", "qwen3.5:9b-mlx" then "qwen3.5:9b-mlx"
  when "qwen3.6:27b", "qwen3.6:27b-mlx" then "qwen3.6:27b-mlx"
  when "qwen3.6:35b", "qwen3.6:35b-mlx" then "qwen3.6:35b-mlx"
  when "qwen3:30b", "qwen3:30b-a3b" then "qwen3:30b"
  when "qwen3:8b", "qwen3:14b" then "qwen3:8b"
  when "devstral-small-2:24b", "gemma4:e4b", "granite4.1:8b", "llama3.2:3b" then "qwen3:8b"
  else cleaned
  end
end

def challenger_model_options
  allowed = CHALLENGER_MODEL_OPTIONS.map(&:last)
  configured = default_challenger_model.to_s.strip
  options = CHALLENGER_MODEL_OPTIONS.dup + configured_challenger_model_options
  options = options.map do |label, model|
    normalized = normalize_challenger_model_alias(model)
    [challenger_model_display_label(normalized).presence || label, normalized]
  end
    .select { |_label, model| allowed.include?(model) }
    .uniq { |_label, model| model }
  if configured.present? && allowed.include?(configured) && options.none? { |_label, model| model == configured }
    options.unshift([challenger_model_display_label(configured), configured])
  end
  options
end

def configured_challenger_model_options
  parse_report_local_model_options(
    ENV["WIZWIKI_CHALLENGER_MODELS"].presence || ENV["ALICE_CHALLENGER_MODELS"].presence
  )
end

def default_challenger_model
  normalize_challenger_model_alias(ENV["WIZWIKI_DEFAULT_CHALLENGER_MODEL"].presence || "qwen3:4b")
end

def challenger_model_display_label(model)
  cleaned = normalize_challenger_model_alias(model)
  case cleaned
  when "qwen3:4b" then "★ Qwen 3 4B // default fastest challenger"
  when "qwen3:8b" then "Qwen 3 8B // fast challenger"
  when "qwen3:14b" then "Qwen 3 14B // deeper challenger"
  when "mistral-small:24b" then "Mistral Small 24B // challenger judge"
  when "gemma3:27b" then "Gemma 3 27B // challenger judge"
  else "Challenger // #{cleaned}"
  end
end

def challenger_model_label(model)
  selected = normalize_challenger_model_alias(model)
  challenger_model_options.find { |_label, value| value == selected }&.first || challenger_model_display_label(selected)
end

def normalize_challenger_model(value)
  allowed_models = challenger_model_options.map(&:last)
  selected = normalize_challenger_model_alias(value.presence || default_challenger_model)
  allowed_models.include?(selected) ? selected : allowed_models.first
end

def normalize_challenger_model_alias(value)
  cleaned = value.to_s.strip
  case cleaned
  when "qwen4", "qwen-4b", "qwen3-4b", "qwen3:4b" then "qwen3:4b"
  when "qwen8", "qwen-8b", "qwen_8b", "qwen3-8b", "qwen3_8b", "qwen3:8b" then "qwen3:8b"
  when "qwen14", "qwen-14b", "qwen3-14b", "qwen3:14b" then "qwen3:14b"
  when "mistral", "mistral-small", "mistral-small:24b", "mistral-small-24b" then "mistral-small:24b"
  when "gemma", "gemma3", "gemma3:27b", "gemma3-27b" then "gemma3:27b"
  else cleaned
  end
end

def sms_writer_model_options
  allowed = SMS_WRITER_MODEL_OPTIONS.map(&:last)
  configured = default_sms_writer_model.to_s.strip
  options = SMS_WRITER_MODEL_OPTIONS.dup + configured_sms_writer_model_options
  options = options.map do |label, model|
    normalized = normalize_sms_writer_model_alias(model)
    [sms_writer_model_display_label(normalized).presence || label, normalized]
  end
    .select { |_label, model| allowed.include?(model) }
    .uniq { |_label, model| model }
  if configured.present? && allowed.include?(configured) && options.none? { |_label, model| model == configured }
    options.unshift([sms_writer_model_display_label(configured), configured])
  end
  options
end

def configured_sms_writer_model_options
  parse_report_local_model_options(
    ENV["WIZWIKI_COMMS_SMS_WRITER_MODELS"].presence || ENV["WIZWIKI_COMMS_DRAFT_WRITER_MODELS"].presence
  )
end

def default_sms_writer_model
  normalize_sms_writer_model_alias(
    ENV["WIZWIKI_COMMS_SMS_DRAFT_MODEL"].presence ||
      ENV["WIZWIKI_COMMS_DRAFT_WRITER_MODEL"].presence ||
      ENV["WIZWIKI_COMMS_DRAFT_MODEL"].presence ||
      ENV["WIZWIKI_COMMS_SELECTOR_MODEL"].presence ||
      "qwen3:30b"
  )
end

def sms_writer_model_display_label(model)
  cleaned = normalize_sms_writer_model_alias(model)
  case cleaned
  when "qwen3:4b" then "Qwen 3 4B // fastest SMS writer"
  when "qwen3:8b" then "Qwen 3 8B // fast SMS writer"
  when "qwen3:14b" then "Qwen 3 14B // stronger SMS writer"
  when "qwen3:30b" then "LOCAL // Alice Qwen 30B"
  when "nvidia:warp" then "WARP // rented GPU SMS"
  when "nvidia:nemotron" then "NEMOTRON // NVIDIA hosted SMS"
  when "openai:gpt" then "OpenAI // cloud SMS"
  else "SMS writer // #{cleaned}"
  end
end

def sms_writer_model_label(model)
  selected = normalize_sms_writer_model_alias(model.presence || default_sms_writer_model)
  sms_writer_model_options.find { |_label, value| value == selected }&.first || sms_writer_model_display_label(selected)
end

def normalize_sms_writer_model(value)
  allowed_models = sms_writer_model_options.map(&:last)
  selected = normalize_sms_writer_model_alias(value.presence || default_sms_writer_model)
  allowed_models.include?(selected) ? selected : allowed_models.first
end

def sms_writer_model_from_request(value, fallback: nil, explicit: false)
  fallback_model = normalize_sms_writer_model(fallback.presence || default_sms_writer_model)
  selected = normalize_sms_writer_model(value.presence || fallback_model)

  if stale_default_sms_writer_model?(selected, preferred_model: fallback_model, explicit: explicit)
    fallback_model
  else
    selected
  end
end

def sms_writer_model_from_metadata(metadata)
  values = metadata.to_h
  selected = normalize_sms_writer_model_alias(values["sms_writer_model"].presence || default_sms_writer_model)
  explicit = ActiveModel::Type::Boolean.new.cast(values["sms_writer_model_explicit"])

  if %w[qwen3:4b qwen3:8b].include?(selected) && !explicit && default_sms_writer_model == "qwen3:30b"
    default_sms_writer_model
  else
    normalize_sms_writer_model(selected)
  end
end

def sms_writer_model_explicit?(model)
  normalize_sms_writer_model(model) != default_sms_writer_model
end

def stale_default_sms_writer_model?(model, preferred_model: nil, explicit: false)
  return false if ActiveModel::Type::Boolean.new.cast(explicit)

  normalize_sms_writer_model_alias(model) == "qwen3:8b" &&
    normalize_sms_writer_model_alias(preferred_model.presence || default_sms_writer_model) == "qwen3:30b" &&
    default_sms_writer_model == "qwen3:30b"
end

def normalize_sms_writer_model_alias(value)
  cleaned = value.to_s.strip
  case cleaned.downcase
  when "qwen4", "qwen-4b", "qwen3-4b", "qwen3:4b" then "qwen3:4b"
  when "qwen8", "qwen-8b", "qwen_8b", "qwen3-8b", "qwen3_8b", "qwen3:8b" then "qwen3:8b"
  when "qwen14", "qwen-14b", "qwen3-14b", "qwen3:14b" then "qwen3:14b"
  when "qwen30", "qwen-30b", "qwen3-30b", "qwen3:30b", "qwen3:30b-a3b" then "qwen3:30b"
  when "warp", "warp:gpu", "gpu:warp", "rented-gpu", "rented_gpu", "nvidia:warp", "nvidia-warp" then "nvidia:warp"
  when "nvidia", "nemotron", "nvidia:nemotron", "nvidia-nemotron", "nemotron:sms", "nvidia:sms" then "nvidia:nemotron"
  when "openai", "openai:gpt", "gpt", "gpt-5.4" then "openai:gpt"
  else cleaned
  end
end

def sms_writer_cloud_model(model)
  case normalize_sms_writer_model_alias(model)
  when "openai:gpt" then openai_model
  when "nvidia:warp"
    ENV["WIZWIKI_WARP_GPU_MODEL"].presence ||
      ENV["WIZWIKI_WARP_NVIDIA_MODEL"].presence ||
      ENV["WIZWIKI_COMMS_WARP_MODEL"].presence ||
      ENV["WIZWIKI_COMMS_GPU_MODEL"].presence ||
      ENV["NVIDIA_WARP_MODEL"].presence ||
      "qwen3:30b"
  when "nvidia:nemotron"
    ENV["WIZWIKI_NEMOTRON_SMS_MODEL"].presence ||
      ENV["WIZWIKI_COMMS_NEMOTRON_MODEL"].presence ||
      ENV["WIZWIKI_COMMS_NVIDIA_MODEL"].presence ||
      ENV["NVIDIA_MODEL"].presence ||
      "nvidia/nemotron-3-nano-omni-30b-a3b-reasoning"
  end
end

def sms_writer_cloud_provider(model)
  case normalize_sms_writer_model_alias(model)
  when "openai:gpt" then "openai"
  when "nvidia:warp", "nvidia:nemotron" then "nvidia"
  end
end

def sms_writer_cloud_configured?(model)
  case normalize_sms_writer_model_alias(model)
  when "openai:gpt" then openai_configured?
  when "nvidia:warp"
    credential_present?(warp_gpu_base_url) &&
      credential_present?(ENV["WIZWIKI_WARP_GPU_API_KEY"].presence || ENV["WIZWIKI_WARP_NVIDIA_API_KEY"].presence || ENV["NVIDIA_API_KEY"].presence || ENV["WIZWIKI_NVIDIA_API_KEY"].presence)
  when "nvidia:nemotron"
    credential_present?(ENV["NVIDIA_API_KEY"].presence || ENV["WIZWIKI_NVIDIA_API_KEY"].presence)
  else false
  end
end

def warp_gpu_base_url
  ENV["WIZWIKI_WARP_GPU_BASE_URL"].presence ||
    ENV["WIZWIKI_WARP_NVIDIA_BASE_URL"].presence ||
    ENV["WIZWIKI_COMMS_WARP_BASE_URL"].presence
end

def report_embedder_model_options
  configured = report_embedder_model.to_s.strip
  allowed = REPORT_EMBEDDER_MODEL_OPTIONS.map(&:last)
  options = REPORT_EMBEDDER_MODEL_OPTIONS.dup + configured_report_embedder_model_options
  options = options.map { |label, model| [report_embedder_model_display_label(normalize_report_embedder_model_alias(model)).presence || label, normalize_report_embedder_model_alias(model)] }
    .select { |_label, model| allowed.include?(model) }
    .uniq { |_label, model| model }
  if configured.present? && allowed.include?(configured) && options.none? { |_label, model| model == configured }
    options.unshift([report_embedder_model_display_label(configured), configured])
  end
  options
end

def configured_report_embedder_model_options
  parse_report_local_model_options(
    ENV["WIZWIKI_REPORT_EMBEDDERS"].presence || ENV["ALICE_EMBEDDERS"].presence
  )
end

def report_embedder_model
  normalize_report_embedder_model_alias(ENV["WIZWIKI_REPORT_EMBEDDER_MODEL"].presence || ENV["ALICE_EMBEDDER_MODEL"].presence || "qwen3-embedding:8b-q4_K_M")
end

def report_embedder_model_display_label(model)
  cleaned = normalize_report_embedder_model_alias(model)
  case cleaned
  when "qwen3-embedding:0.6b" then "Qwen Embed 0.6B // fastest context"
  when "qwen3-embedding:4b" then "Qwen Embed 4B // balanced fallback context"
  when "qwen3-embedding", "qwen3-embedding:8b", "qwen3-embedding:8b-q4_K_M" then "★ Qwen Embed 8B Q4 // default deep context"
  when "bge-m3" then "BGE-M3 // retrieval baseline"
  else "Alice embedder // #{cleaned}"
  end
end

def report_embedder_model_label(model)
  selected = normalize_report_embedder_model_alias(model)
  report_embedder_model_options.find { |_label, value| value == selected }&.first || report_embedder_model_display_label(selected)
end

def normalize_report_embedder_model(value)
  allowed_models = report_embedder_model_options.map(&:last)
  selected = normalize_report_embedder_model_alias(value)
  allowed_models.include?(selected) ? selected : allowed_models.first
end

def normalize_report_embedder_model_alias(value)
  cleaned = value.to_s.strip
  case cleaned
  when "qwen3-embedding:0.6b" then "qwen3-embedding:0.6b"
  when "nomic-embed-text", "nomic-embed-text-v2-moe", "embeddinggemma", "mxbai-embed-large", "bge-m3" then "qwen3-embedding:8b-q4_K_M"
  else cleaned
  end
end

def report_lane_options
  REPORT_LANE_OPTIONS.map { |lane| normalized_report_lane(lane) }
end

def default_report_lane
  selected_model = qwen_model
  selected_embedder = report_embedder_model
  report_lane_options.find do |lane|
    lane[:report_local_model] == selected_model &&
      lane[:report_embedder_model] == selected_embedder
  end || report_lane_options.first
end

def report_lane(value)
  selected = value.to_s.strip
  report_lane_options.find { |lane| lane[:value] == selected } || default_report_lane
end

def report_lane_label(value)
  report_lane(value)[:label]
end

def normalized_report_lane(lane)
  local_model = normalize_report_local_model(lane.fetch(:report_local_model))
  ladder = Array(lane[:report_model_ladder].presence || [local_model])
    .map { |model| normalize_report_local_model(model) }
    .reject(&:blank?)
  {
    value: lane.fetch(:value).to_s,
    label: lane.fetch(:label).to_s,
    description: lane.fetch(:description).to_s,
    report_local_model: local_model,
    report_model_ladder: ladder.presence || [local_model],
    report_embedder_model: normalize_report_embedder_model(lane.fetch(:report_embedder_model))
  }
end

  def wizwiki_report_reasoning_effort
    return "local" if qwen_only?

    ENV["WIZWIKI_REPORT_REASONING_EFFORT"].presence || "xhigh"
  end

  def truthy?(value)
    %w[1 true yes on].include?(value.to_s.strip.downcase)
  end

  def credential_present?(value)
    cleaned = value.to_s.strip
    cleaned.present? && !cleaned.start_with?("YOUR_")
  end

  def normalize_openai_reasoning_effort(value)
    cleaned = value.to_s.strip.downcase.tr("-", "_")
    return if cleaned.blank? || cleaned == "default" || cleaned == "none"
    return "xhigh" if %w[xhigh x_high extra_high extra].include?(cleaned)

    cleaned
  end

  def package_config(package)
    square.fetch("quick_cart_packages", {}).to_h.fetch(package.to_s.upcase, {}).to_h
  end
end
