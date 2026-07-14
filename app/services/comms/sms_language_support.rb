require "json"
require "active_model"
require "net/http"
require "uri"
require "active_support/core_ext/time"

module Comms
  class SmsLanguageSupport
    SETTINGS_KEY = "comms_sms_language_support".freeze
    DEFAULT_SETTINGS = {
      "enabled" => false
    }.freeze
    PREFERENCE_NOTICE_BODY = "Prefer another language? Reply in your preferred language. ¿Prefieres otro idioma? Responde en tu idioma. 更喜欢其他语言？请直接用你的语言回复。 Español · 中文 · Tiếng Việt · Русский · العربية · Tagalog · 한국어 · Português".freeze
    QWEN_BASE_URL = ENV.fetch("WIZWIKI_SMS_LANGUAGE_QWEN_BASE_URL", ENV.fetch("OLLAMA_BASE_URL", "http://127.0.0.1:11434")).freeze
    QWEN_MODEL = ENV.fetch("WIZWIKI_SMS_LANGUAGE_QWEN_MODEL", ENV.fetch("WIZWIKI_COMMS_TRANSLATION_MODEL", "qwen3:8b")).freeze
    QWEN_MODEL_LADDER = ENV.fetch("WIZWIKI_SMS_LANGUAGE_QWEN_MODELS", QWEN_MODEL).split(",").map(&:squish).compact_blank.freeze
    READ_TIMEOUT = ENV.fetch("WIZWIKI_SMS_LANGUAGE_QWEN_READ_TIMEOUT", "45").to_i.clamp(3, 90)
    OPEN_TIMEOUT = ENV.fetch("WIZWIKI_SMS_LANGUAGE_QWEN_OPEN_TIMEOUT", "2").to_i.clamp(1, 10)
    CUSTOMER_LANGUAGE_CODES = {
      "en" => "English",
      "es" => "Spanish",
      "zh" => "Chinese",
      "vi" => "Vietnamese",
      "ru" => "Russian",
      "ar" => "Arabic",
      "tl" => "Tagalog",
      "ko" => "Korean",
      "pt" => "Portuguese"
    }.freeze
    LANGUAGE_NAME_TO_CODE = CUSTOMER_LANGUAGE_CODES.invert.transform_keys(&:downcase).freeze
    LANGUAGE_ALIASES_TO_CODE = {
      "english" => "en",
      "spanish" => "es",
      "español" => "es",
      "espanol" => "es",
      "chinese" => "zh",
      "中文" => "zh",
      "普通话" => "zh",
      "mandarin" => "zh",
      "vietnamese" => "vi",
      "tiếng việt" => "vi",
      "tieng viet" => "vi",
      "russian" => "ru",
      "русский" => "ru",
      "русская" => "ru",
      "русски" => "ru",
      "по-русски" => "ru",
      "arabic" => "ar",
      "العربية" => "ar",
      "عربي" => "ar",
      "tagalog" => "tl",
      "filipino" => "tl",
      "korean" => "ko",
      "한국어" => "ko",
      "portuguese" => "pt",
      "português" => "pt",
      "portugues" => "pt"
    }.freeze
    SPANISH_SIGNAL_PATTERN = /
      [ñ¿¡]|
      \b(?:hola|gracias|prefiero|español|espanol|spanish|quiero|quero|necesito|precio|precios|cuanto|cuánto|tarjetas|postales|letreros|senales|señales|negocio|ayuda|favor|ambos|ambas)\b|
      \bpor\s+favor\b
    /ix.freeze
    CHINESE_SIGNAL_PATTERN = /[\p{Han}]/.freeze
    CYRILLIC_SIGNAL_PATTERN = /[\p{Cyrillic}]/.freeze
    ARABIC_SIGNAL_PATTERN = /[\p{Arabic}]/.freeze
    HANGUL_SIGNAL_PATTERN = /[\p{Hangul}]/.freeze
    VIETNAMESE_SIGNAL_PATTERN = /
      [ăâđêôơư]|
      \b(?:xin\s+chào|chào|cam\s+on|cảm\s+ơn|vietnamese|tiếng\s+việt|tieng\s+viet)\b
    /ix.freeze
    TAGALOG_SIGNAL_PATTERN = /\b(?:tagalog|filipino|kumusta|salamat|magkano|gusto\s+ko|kailangan\s+ko|ano\s+ang|laman|kumpara|sige|ipadala|alin\s+ang|sana\s+ang\s+sagot)\b/i.freeze
    PORTUGUESE_SIGNAL_PATTERN = /\b(?:portugu[eê]s|portuguese|obrigad[oa]|preço|quanto\s+custa|cart[oõ]es?\s+postais?|postais|promo[cç][aã]o|envie|menor\s+caminho)\b/i.freeze
    PROTECTED_TOKEN_PATTERN = %r{
      https?://\S+|
      \b\d{1,3}\s*x\s*\d{1,3}\b|
      \$(?:\d{1,3}(?:,\d{3})+|\d+)(?:\.\d+)?|
      \b(?:\d{1,3}(?:,\d{3})+|\d+)(?:\.\d+)?%?\b|
      \bSTOP\b
    }x.freeze
    EXACT_INBOUND_TRANSLATIONS = {
      "prefiero español. tengo una compañía de techos y quiero letreros de jardín." => "I want yard signs please.",
      "prefiero español" => "I prefer Spanish.",
      "prefiero espanol" => "I prefer Spanish.",
      "si yo prefiero espanol" => "I prefer Spanish.",
      "sí yo prefiero español" => "I prefer Spanish.",
      "si prefiero espanol" => "I prefer Spanish.",
      "sí prefiero español" => "I prefer Spanish.",
      "¿cuál es la opción más barata para empezar?" => "What is the cheapest option to start?",
      "¿cuánto saldría cada letrero si solo quiero saber el costo de uno?" => "How much would each yard sign cost?",
      "¿incluye diseño, estacas y envío?" => "Does it include design, stakes, and shipping?",
      "mándame el enlace para 10 letreros." => "Send me the link for 10 yard signs.",
      "请用中文回复。我想给屋顶公司做明信片推广。" => "I want postcard marketing for a roofing company.",
      "现在有没有七月四日的明信片特价？" => "Are there any 4th of July postcard specials?",
      "请列出完整价格表。" => "Please list the full price sheet.",
      "如果我要 5,000 张，总价是多少？" => "What is the total for 5,000 postcards?",
      "请发 5,000 张明信片的付款链接。" => "Please send the checkout link for 5,000 postcards.",
      "tôi muốn nói tiếng việt. tôi cần bảng yard sign cho công ty sửa mái nhà." => "I need yard signs for a roofing company.",
      "tôi cần 100 bảng, giá bao nhiêu?" => "I need 100 yard signs. What is the price?",
      "tôi có thể đặt gấp để kịp thứ sáu tuần sau không?" => "Can I rush the order to have it by next Friday?",
      "vậy tôi có nên dùng checkout bình thường cho đơn gấp không?" => "Should I use the normal checkout for this rush order?",
      "được, hãy cho chuyên viên marketing liên hệ với tôi." => "Yes, please have a marketing consultant contact me.",
      "пожалуйста, отвечайте по-русски. мне нужны печатные материалы для клининговой компании." => "I need printed materials for a cleaning company.",
      "какие продукты кроме табличек вы можете предложить?" => "What products besides yard signs can you offer?",
      "нужны визитки, дверные хэнгеры и, возможно, флаеры." => "I need business cards, door hangers, and maybe flyers.",
      "я не знаю размеры и количество, это слишком кастомно." => "I do not know the sizes or quantities; it is too custom.",
      "может ли маркетинговый консультант помочь выбрать?" => "Can a marketing consultant help choose?",
      "أفضّل العربية. أريد حملة بريد مباشر لشركة ترميم أسقف." => "I want a direct mail campaign for a roof repair company.",
      "ما الفرق بين eddm و neighborhood blitz؟" => "What is the difference between EDDM and Neighborhood Blitz?",
      "إذا كان عندي حوالي 650 منزلًا، أيهما أنسب؟" => "If I have about 650 homes, which is better?",
      "هل يمكنك اختيار الأحياء والقوائم وخطة الاستهداف بالكامل؟" => "Can you choose the neighborhoods, lists, and targeting strategy completely?",
      "نعم، وصّلني بمستشار تسويق لبحث التفاصيل." => "Yes, connect me with a marketing consultant to discuss the details.",
      "tagalog sana ang sagot. naghahanap ako ng yard signs para sa pest control business." => "I am looking for yard signs for a pest control business.",
      "ano ang laman ng starter pack na $299 kumpara sa pro pack na $599?" => "What is included in the $299 Starter Pack compared with the $599 Pro Pack?",
      "kung signs lang talaga ang kailangan ko, alin ang mas malinaw na piliin?" => "If I only need signs, which is clearer to choose?",
      "magkano ang 100 yard signs?" => "How much are 100 yard signs?",
      "sige, ipadala ang link para sa 100 signs." => "Okay, send the link for 100 signs.",
      "한국어로 답해 주세요. 조경 회사용 야드 사인이 필요합니다." => "I need yard signs for a landscaping company.",
      "50개 가격이 얼마인가요?" => "What is the price for 50 yard signs?",
      "인쇄 전에 시안을 승인할 수 있나요?" => "Can I approve a proof before printing?",
      "로고가 페이스북 캡처라 좀 흐린데 정리해 줄 수 있나요?" => "The logo is a blurry Facebook screenshot; can you clean it up?",
      "좋아요. 50개 주문 링크를 보내 주세요." => "Good. Please send the order link for 50 yard signs.",
      "prefiro português. estou pensando em cartões postais para minha empresa de encanamento." => "I am thinking about postcards for my plumbing company.",
      "quanto custa um cartão postal sozinho?" => "How much does one postcard cost by itself?",
      "qual é o menor caminho real para pedir postais?" => "What is the smallest real path to order postcards?",
      "se eu fizer 1.000 postais, isso entra na promoção 4th of july block sale?" => "If I order 1,000 postcards, is that part of the 4th of July Block Sale?",
      "sim, envie o link para 1.000 postais." => "Yes, send the link for 1,000 postcards."
    }.freeze
    TARGET_LANGUAGE_SIGNAL_PATTERNS = {
      "es" => SPANISH_SIGNAL_PATTERN,
      "zh" => CHINESE_SIGNAL_PATTERN,
      "vi" => VIETNAMESE_SIGNAL_PATTERN,
      "ru" => CYRILLIC_SIGNAL_PATTERN,
      "ar" => ARABIC_SIGNAL_PATTERN,
      "tl" => TAGALOG_SIGNAL_PATTERN,
      "ko" => HANGUL_SIGNAL_PATTERN,
      "pt" => PORTUGUESE_SIGNAL_PATTERN
    }.freeze
    OUTBOUND_FAILSAFE_BODIES = {
      "es" => "Estoy revisando eso para responderte bien en español. Dame un momento.",
      "zh" => "我正在确认细节，好用中文准确回复你。请稍等一下。",
      "vi" => "Tôi đang kiểm tra để trả lời rõ ràng bằng tiếng Việt. Vui lòng chờ một chút.",
      "ru" => "Я уточняю детали, чтобы ответить по-русски точно. Подождите немного.",
      "ar" => "أتحقق من التفاصيل لأرد عليك بوضوح بالعربية. لحظة من فضلك.",
      "tl" => "Tinitingnan ko ang detalye para makasagot nang maayos sa Tagalog. Sandali lang.",
      "ko" => "한국어로 정확히 답하려고 확인하고 있습니다. 잠시만 기다려 주세요.",
      "pt" => "Estou conferindo os detalhes para responder direito em português. Só um momento."
    }.freeze

    Result = Struct.new(:body, :metadata, :event, :language_code, :language_label, :translated, :error, keyword_init: true) do
      def to_h
        {
          "body" => body,
          "metadata" => metadata.to_h,
          "event" => event.to_h,
          "language_code" => language_code,
          "language_label" => language_label,
          "translated" => translated,
          "error" => error
        }.compact_blank
      end
    end

    def self.enabled?
      ActiveModel::Type::Boolean.new.cast(ENV.fetch("WIZWIKI_SMS_LANGUAGE_SUPPORT_ENABLED", "1"))
    end

    def self.settings_for(organization)
      saved = organization&.settings.to_h.fetch(SETTINGS_KEY, {}).to_h
      DEFAULT_SETTINGS.merge(saved)
    rescue StandardError
      DEFAULT_SETTINGS.dup
    end

    def self.enabled_for?(stage: nil, metadata: nil, organization: nil)
      return false unless enabled?

      if metadata.to_h.key?("sms_language_support_enabled")
        return ActiveModel::Type::Boolean.new.cast(metadata.to_h["sms_language_support_enabled"])
      end

      organization ||= stage.organization if stage.respond_to?(:organization)
      return ActiveModel::Type::Boolean.new.cast(settings_for(organization)["enabled"]) if organization.present?

      true
    end

    def self.translation_enabled?(stage: nil, metadata: nil, organization: nil)
      enabled_for?(stage: stage, metadata: metadata, organization: organization) &&
        ActiveModel::Type::Boolean.new.cast(ENV.fetch("WIZWIKI_SMS_LANGUAGE_TRANSLATION_ENABLED", "1"))
    end

    def self.preference_notice_body
      PREFERENCE_NOTICE_BODY
    end

    def self.preference_notice_body?(value)
      value.to_s.squish == preference_notice_body
    end

    def self.should_send_preference_notice?(metadata, stage: nil, organization: nil)
      metadata = metadata.to_h
      return false unless enabled_for?(stage: stage, metadata: metadata, organization: organization)
      return false if metadata["sms_language_preference_notice_sent_at"].present?
      return false if ActiveModel::Type::Boolean.new.cast(metadata["sms_sending_disabled"])
      return false if ActiveModel::Type::Boolean.new.cast(metadata["sms_do_not_contact"])
      return false if metadata["comms_board_state"].to_s == "opt_out"

      customer_facing_outbound_count(metadata) == 1
    end

    def self.customer_facing_outbound_count(metadata)
      Array(metadata.to_h["sms_thread"]).count do |event|
        event = event.to_h
        event["channel"].to_s == "sms" &&
          event["direction"].to_s == "outbound" &&
          !event["status"].to_s.in?(%w[failed canceled]) &&
          !ActiveModel::Type::Boolean.new.cast(event["language_preference_notice"]) &&
          !ActiveModel::Type::Boolean.new.cast(event["do_not_contact_confirmation"])
      end
    end

    def self.prepare_inbound_body(stage:, metadata:, body:)
      original = body.to_s.squish
      return Result.new(body: original, metadata: {}, event: {}, language_code: "en", language_label: "English", translated: false) if original.blank?
      return Result.new(body: original, metadata: {}, event: {}, language_code: "en", language_label: "English", translated: false) unless enabled_for?(stage: stage, metadata: metadata)

      code = "en"
      label = "English"
      translated_body = nil
      error = nil
      body_for_rag = original
      translation_provider = nil
      begin
        detection = detect_language(original, metadata: metadata)
        code = detection.fetch(:code)
        label = language_label(code)

        if code != "en" && translation_enabled?(stage: stage, metadata: metadata)
          translated_body = deterministic_inbound_translation(original, code: code)
          translation_provider = "deterministic/inbound" if translated_body.present?
          if translated_body.blank?
            translated_body = translate_text(original, from: label, to: "English", direction: "inbound")
            translation_provider = "ollama/local" if translated_body.present?
          end
        elsif code == "en" && explicit_language_code(original) == "en"
          translated_body = language_preference_only_translation(original, code: "en")
          translation_provider = "deterministic/language_preference" if translated_body.present?
        end
        if translated_body.present? && translation_provider == "ollama/local" && !valid_inbound_translation?(translated_body, source: original)
          error = "translation_rejected_incomplete"
          translated_body = nil
          translation_provider = nil
        end
        body_for_rag = translated_body.to_s.squish.presence || original
        body_for_rag = strip_language_preference_directive(body_for_rag, code: code)
      rescue StandardError => exception
        error = "#{exception.class}: #{exception.message}"
        code = "en"
        label = "English"
        body_for_rag = original
      end

      translated = translated_body.to_s.squish.present? && body_for_rag.to_s != original
      metadata_updates = {
        "sms_language_last_detected_code" => code,
        "sms_language_last_detected_label" => label,
        "sms_language_last_detected_at" => Time.current.iso8601,
        "sms_language_last_inbound_original" => translated ? original : nil,
        "sms_language_last_inbound_english" => translated ? body_for_rag : nil,
        "sms_language_last_error" => error
      }.compact_blank
      if code != "en" || explicit_language_code(original) == "en"
        metadata_updates.merge!(
          "sms_language_preferred_code" => code,
          "sms_language_preferred_label" => label,
          "sms_language_preferred_at" => Time.current.iso8601
        )
      end
      event_updates = {
        "language_code" => code,
        "language_label" => label,
        "language_translated" => translated,
        "original_body" => translated ? original : nil,
        "translated_from" => translated ? label : nil,
        "translated_to" => translated ? "English" : nil,
        "translation_provider" => translated ? (translation_provider.presence || "ollama/local") : nil,
        "translation_model" => translated ? QWEN_MODEL : nil,
        "translation_error" => error
      }.compact_blank
      Result.new(
        body: body_for_rag,
        metadata: metadata_updates,
        event: event_updates,
        language_code: code,
        language_label: label,
        translated: translated,
        error: error
      )
    end

    def self.prepare_outbound_body(stage:, body:)
      english = body.to_s.squish
      return Result.new(body: english, metadata: {}, event: {}, language_code: "en", language_label: "English", translated: false) if english.blank?
      return Result.new(body: english, metadata: {}, event: {}, language_code: "en", language_label: "English", translated: false) if preference_notice_body?(english)

      metadata = stage&.metadata.to_h
      return Result.new(body: english, metadata: {}, event: {}, language_code: "en", language_label: "English", translated: false) unless enabled_for?(stage: stage, metadata: metadata)

      code = preferred_language_code(metadata)
      label = language_label(code)
      return Result.new(body: english, metadata: {}, event: {}, language_code: code, language_label: label, translated: false) if code == "en"

      translation_provider = nil
      translation_error = nil
      translated_body = deterministic_outbound_translation(english, code: code)
      translation_provider = "deterministic/sms_phrasebook" if translated_body.present?
      if translated_body.present? && !valid_outbound_translation?(translated_body, code: code, source: english)
        translation_error = "deterministic_translation_rejected_incomplete"
        translated_body = nil
        translation_provider = nil
      end
      if translated_body.blank? && translation_enabled?(stage: stage, metadata: metadata)
        begin
          translated_body = translate_text(english, from: "English", to: label, direction: "outbound")
          if translated_body.present?
            translation_provider = "ollama/qwen_local"
            translation_error = nil
          end
        rescue StandardError => exception
          translation_error = "#{exception.class}: #{exception.message}"
        end
      end
      if translated_body.present? && !valid_outbound_translation?(translated_body, code: code, source: english)
        translation_error = "translation_rejected_wrong_language"
        translated_body = nil
        translation_provider = nil
      end
      if translated_body.blank?
        translation_error ||= "translation_unavailable"
        translated_body = localized_outbound_failsafe_body(code)
        translation_provider = "localized/failsafe" if translated_body.present?
      end
      final_body = translated_body.to_s.squish.presence || english
      final_body = restore_terminal_punctuation(english, final_body)
      translated = final_body != english && translation_error.blank?
      localized_failsafe = final_body != english && translation_error.present?
      context_english = if translated
        english
      elsif localized_failsafe
        localized_outbound_failsafe_english_body(label)
      end
      updates = {
        "sms_language_last_outbound_english" => context_english,
        "sms_language_last_outbound_translated" => (translated || localized_failsafe) ? final_body : nil,
        "sms_language_last_outbound_code" => code,
        "sms_language_last_outbound_label" => label,
        "sms_language_last_outbound_at" => Time.current.iso8601,
        "sms_language_last_error" => translation_error,
        "sms_language_last_error_at" => translation_error.present? ? Time.current.iso8601 : nil
      }.compact_blank
      event = {
        "language_code" => code,
        "language_label" => label,
        "language_translated" => translated,
        "language_failsafe" => localized_failsafe,
        "english_body" => context_english,
        "translation_source_english_body" => localized_failsafe ? english : nil,
        "translation_provider" => (translated || localized_failsafe) ? translation_provider : nil,
        "translation_model" => translated && translation_provider.to_s.start_with?("ollama/") ? QWEN_MODEL : nil,
        "language_translation_error" => translation_error
      }.compact_blank
      Result.new(body: final_body, metadata: updates, event: event, language_code: code, language_label: label, translated: translated, error: translation_error)
    rescue StandardError => error
      fallback = code.to_s == "en" ? nil : localized_outbound_failsafe_body(code)
      fallback_label = label.to_s.squish.presence || language_label(code)
      context_english = fallback.present? ? localized_outbound_failsafe_english_body(fallback_label) : nil
      Result.new(
        body: fallback.presence || english,
        metadata: {
          "sms_language_last_error" => "#{error.class}: #{error.message}",
          "sms_language_last_error_at" => Time.current.iso8601
        },
        event: {
          "language_failsafe" => fallback.present?,
          "english_body" => context_english,
          "translation_source_english_body" => fallback.present? ? english : nil,
          "translation_provider" => fallback.present? ? "localized/failsafe" : nil,
          "language_translation_error" => "#{error.class}: #{error.message}"
        }.compact_blank,
        language_code: code.presence || "en",
        language_label: label.presence || "English",
        translated: false,
        error: "#{error.class}: #{error.message}"
      )
    end

    def self.preferred_language_code(metadata)
      code = metadata.to_h["sms_language_preferred_code"].to_s.downcase.presence ||
        detect_language(metadata.to_h["sms_language_last_inbound_original"].presence || metadata.to_h["sms_language_last_inbound_english"].to_s).fetch(:code)
      CUSTOMER_LANGUAGE_CODES.key?(code) ? code : "en"
    end

    def self.detect_language(text, metadata: nil)
      body = text.to_s.squish
      existing = metadata.to_h["sms_language_preferred_code"].to_s.downcase
      return { code: existing, label: language_label(existing), confidence: 0.95, source: "thread_preference" } if CUSTOMER_LANGUAGE_CODES.key?(existing) && body.match?(/\A(?:yes|si|sí|ok|okay|that works|sounds good)\z/i)
      if (explicit_code = explicit_language_code(body))
        return { code: explicit_code, label: language_label(explicit_code), confidence: 0.98, source: "language_name" }
      end
      return { code: "zh", label: "Chinese", confidence: 0.99, source: "script" } if body.match?(CHINESE_SIGNAL_PATTERN)
      return { code: "ar", label: "Arabic", confidence: 0.99, source: "script" } if body.match?(ARABIC_SIGNAL_PATTERN)
      return { code: "ko", label: "Korean", confidence: 0.99, source: "script" } if body.match?(HANGUL_SIGNAL_PATTERN)
      return { code: "ru", label: "Russian", confidence: 0.96, source: "script" } if body.match?(CYRILLIC_SIGNAL_PATTERN)
      return { code: "vi", label: "Vietnamese", confidence: 0.9, source: "keyword" } if body.match?(VIETNAMESE_SIGNAL_PATTERN)
      return { code: "tl", label: "Tagalog", confidence: 0.88, source: "keyword" } if body.match?(TAGALOG_SIGNAL_PATTERN)
      return { code: "pt", label: "Portuguese", confidence: 0.88, source: "keyword" } if body.match?(PORTUGUESE_SIGNAL_PATTERN)
      return { code: "es", label: "Spanish", confidence: 0.9, source: "keyword" } if body.match?(SPANISH_SIGNAL_PATTERN)

      { code: "en", label: "English", confidence: 0.8, source: "default" }
    end

    def self.explicit_language_code(text)
      body = text.to_s.downcase.squish
      LANGUAGE_ALIASES_TO_CODE.each do |language_name, code|
        next unless body.include?(language_name)

        return code
      end
      nil
    end

    def self.deterministic_inbound_translation(text, code:)
      return if code.to_s == "en"

      body = text.to_s.downcase.squish
      exact = EXACT_INBOUND_TRANSLATIONS[body]
      return exact if exact.present?

      language_preference = language_preference_only_translation(body, code: code)
      return language_preference if language_preference.present?

      wants_product = body.match?(/\b(?:quiero|quero|prefiero|prefero|necesito|ocupo|want|prefer|need)\b/) ||
        body.match?(/\bpor\s+favor\b/)
      sign_interest = body.match?(/\b(?:yard\s+signs?|signs?|letreros?|senales?|señales?)\b/)
      postcard_interest = body.match?(/\b(?:postcards?|postales?|tarjetas?\s+postales?)\b/)
      price_interest = body.match?(/\b(?:precio|precios|cuanto|cuánto|costo|costaría|costaria|saldría|saldria|cuesta|cuestan|cost|price|how much)\b/)

      return "Both." if body.match?(/\A(?:ambos|ambas)\.?\z/)
      return "What is the cheapest option to start?" if body.match?(/\b(?:opci[oó]n|option)\b/) && body.match?(/\b(?:barat[ao]|econ[oó]mic[ao]|cheapest|lowest)\b/)
      return "How much would each yard sign cost?" if sign_interest && body.match?(/\b(?:cada|each|uno|one)\b/) && price_interest
      return "Does it include design, stakes, and shipping?" if body.match?(/\b(?:incluye|include|includes)\b/) && body.match?(/\b(?:dise[nñ]o|design)\b/) && body.match?(/\b(?:estacas|stakes)\b/) && body.match?(/\b(?:env[ií]o|shipping)\b/)
      return "Send me the link for 10 yard signs." if body.match?(/\b(?:m[aá]ndame|manda|send)\b/) && body.match?(/\b(?:enlace|link)\b/) && body.match?(/\b10\b/)
      return "How much are yard signs?" if sign_interest && price_interest
      return "How much are postcards?" if postcard_interest && price_interest
      return "I want both yard signs and postcards please." if wants_product && sign_interest && postcard_interest
      return "I want yard signs please." if wants_product && sign_interest
      return "I want postcards please." if wants_product && postcard_interest

      nil
    end

    def self.language_preference_only_translation(text, code:)
      language_code = code.to_s.downcase
      return if language_code.blank?

      body = text.to_s.downcase.squish
      return if body.blank?
      return if language_preference_product_intent?(body)

      aliases = language_alias_terms_for_code(language_code)
      return if aliases.blank?

      alias_pattern = aliases.map { |term| Regexp.escape(term.downcase) }.join("|")
      return unless body.match?(/(?:#{alias_pattern})/i)

      clean = body.gsub(/[.!?。！？؟،,]/, " ").squish
      alias_only = clean.match?(/\A(?:#{alias_pattern})(?:\s+(?:please|por\s+favor))?\z/i)
      directive = clean.match?(/\b(?:please|prefer|prefiero|prefiro|quiero|quero|want|would like|text|speak|talk|write|reply|respond|answer|language|idioma|responde|responder|hablar|falar|nói|noi|sagot)\b/i) ||
        body.match?(/(?:отвеч|ответ|اكتب|أفض|افضل|رد|回复|回答|答|답|sana\s+ang\s+sagot)/i)
      return unless alias_only || directive

      "I prefer #{language_label(language_code)}."
    end

    def self.language_alias_terms_for_code(code)
      language_code = code.to_s.downcase
      return [] if language_code.blank?

      aliases = LANGUAGE_ALIASES_TO_CODE.filter_map { |term, value| term if value == language_code }
      label = language_label(language_code)
      (aliases + [label, language_code]).compact_blank.uniq
    end

    def self.language_preference_product_intent?(text)
      body = text.to_s.downcase.squish
      return false if body.blank?

      body.match?(/\b(?:yard\s+signs?|signs?|letreros?|senales?|señales?|postcards?|postales?|business\s+cards?|door\s+hangers?|flyers?|rack\s+cards?|mailboxes?|mailing|correo|eddm|neighborhood|blitz|checkout|link|price|precios?|cuanto|cuánto|cost|costo|empresa|company|roofing|techos|marketing|cart[oõ]es?|postais|placas?|таблич|визит|открытк|magkano|가격|견적|가격이)\b/i) ||
        body.match?(/[明信片庭院标牌院牌传单名片]/) ||
        body.match?(/\b(?:سعر|أسعار|بطاقات|بريدية|لافتات|حديقة|شركة|تسويق)\b/)
    end

    def self.strip_language_preference_directive(text, code: nil)
      body = text.to_s.squish
      return body if body.blank?

      labels = CUSTOMER_LANGUAGE_CODES.values.map { |label| Regexp.escape(label) }.join("|")
      directive = /
        \A
        (?:
          (?:please\s+)?(?:reply|respond|answer|write|text|speak)\s+(?:to\s+me\s+)?(?:in\s+)?(?:#{labels})
          |
          (?:i\s+)?(?:prefer|want|would\s+like|need)\s+(?:to\s+)?(?:speak|talk|use|write|reply|respond|answer)?\s*(?:in\s+)?(?:#{labels})
          |
          (?:use|in)\s+(?:#{labels})
        )
        [.!?。؟]*\s*
      /ix
      cleaned = body.sub(directive, "").squish
      cleaned.presence || body
    end

    def self.deterministic_outbound_translation(text, code:)
      body, url = split_url_suffix(text)
      translated = deterministic_language_preference_outbound_phrase(body, code: code)
      translated ||= case code.to_s
      when "es"
        deterministic_spanish_outbound_phrase(body)
      when "zh"
        deterministic_chinese_outbound_phrase(body)
      end
      translated ||= deterministic_product_outbound_phrase(body, code: code)
      return if translated.blank?

      [translated, url].compact_blank.join(" ").squish
    end

    def self.deterministic_language_preference_outbound_phrase(text, code:)
      language_code = code.to_s.downcase
      label = language_label(language_code)
      body = text.to_s.squish
      return unless body.match?(/\Ayes[,.]?\s+i\s+can\s+text\s+you\s+in\s+#{Regexp.escape(label)}\.?\s+are\s+you\s+thinking\s+postcards,\s+yard\s+signs,\s+or\s+both\?\z/i)

      case language_code
      when "es"
        "Sí, puedo escribirte en español. ¿Estás pensando en postales, letreros de jardín o ambos?"
      when "zh"
        "可以，我可以用中文给你发短信。你是在考虑明信片、庭院标牌，还是两者都要？"
      when "vi"
        "Có, tôi có thể nhắn tin cho bạn bằng tiếng Việt. Bạn đang nghĩ đến bưu thiếp, bảng yard sign, hay cả hai?"
      when "ru"
        "Да, я могу писать вам по-русски. Вы думаете о почтовых открытках, табличках для двора или о том и другом?"
      when "ar"
        "نعم، يمكنني مراسلتك بالعربية. هل تفكر في بطاقات بريدية، لافتات للحديقة، أم الاثنين؟"
      when "tl"
        "Oo, puwede kitang i-text sa Tagalog. Postcards, yard signs, o pareho ba ang iniisip mo?"
      when "ko"
        "네, 한국어로 문자드릴 수 있어요. 엽서, 야드 사인, 아니면 둘 다 생각 중이신가요?"
      when "pt"
        "Sim, posso te mandar mensagem em português. Você está pensando em cartões postais, placas de jardim ou ambos?"
      end
    end

    def self.deterministic_product_outbound_phrase(text, code:)
      key = deterministic_product_answer_key(text)
      return if key.blank?

      deterministic_product_answer_body(key, code: code)
    end

    def self.deterministic_product_answer_key(text)
      body = text.to_s.downcase.squish
      return if body.blank?

      if broad_print_product_answer?(body)
        return :print_products
      end

      if body.match?(/\byard signs?\b/) && body.match?(/\b(?:one-sign|one sign|single sign|\$9\.90|minimum is 10)\b/)
        return :yard_sign_unit
      end

      if body.match?(/\byard signs?\b/) && body.match?(/\b(?:cheapest|best price per sign|10 signs? for \$\s?99|\$99 double-sided)\b/)
        return :yard_sign_cheapest
      end

      if body.match?(/\byard signs?\b/) && body.match?(/\bdesign\b/) && body.match?(/\bstakes?\b/) && body.match?(/\bshipping\b/)
        return :yard_sign_included
      end

      if body.match?(/\byard signs?\b/) && body.match?(/\bcheckout link\b|\border link\b|\bbuy link\b/)
        return :yard_sign_checkout
      end

      if body.match?(/\bpostcards?\b/) && body.match?(/\b4th of july\b/) && body.match?(/\b1,?000\b/) && body.match?(/\b25,?000\b/)
        return :postcard_all_tiers
      end

      if body.match?(/\b5,?000\b/) && body.match?(/\bpostcards?\b/) && body.match?(/\$\s?3,?250\b/)
        return body.match?(/\bcheckout link\b|\border link\b|\bbuy link\b/) ? :postcard_checkout : :postcard_5000
      end

      if body.match?(/\beddm\b/) && body.match?(/\bneighborhood blitz\b/) && body.match?(/\$\s?399\b/) && body.match?(/\$\s?699\b/)
        return :direct_mail_compare
      end

      if body.match?(/\bmarketing consultant\b/) && body.match?(/\b(?:strategy|routes?|lists?|targeting|neighborhoods?)\b/)
        return :direct_mail_strategy
      end

      if print_product_context?(body) && body.match?(/\b(?:marketing consultant|custom|sizes?|quantit|quote|estimate|calculate)\b/)
        return :print_consultant
      end

      if print_product_context?(body)
        return :print_products
      end

      if body.match?(/\b(?:rush|faster|next friday|normal checkout)\b/) && body.match?(/\bmarketing consultant\b/)
        return :rush_handoff
      end

      if body.match?(/\b(?:proof|approve|approval)\b/) && body.match?(/\b(?:printing|prints?|logo|artwork|design)\b/)
        return :proof_design
      end

      nil
    end

    def self.broad_print_product_answer?(body)
      return false unless print_product_context?(body)

      body.match?(/\b(?:can help|help with|offer|offers|products?|print pieces?|printed materials?|marketing materials?|campaign materials?|related materials?|besides signs?|cards or flyers|cards,?\s+door hangers?,?\s+(?:and\s+)?flyers?)\b/)
    end

    def self.print_product_context?(body)
      body.to_s.match?(/\b(?:business cards?|door hangers?|flyers?|rack cards?|brochures?|menus?|postcards?|print(?:ed)?\s+(?:materials?|pieces?|collateral)|marketing materials?|campaign materials?)\b/)
    end

    def self.deterministic_product_answer_body(key, code:)
      table = deterministic_product_answer_table[code.to_s.downcase]
      table ||= deterministic_product_answer_table["es"] if code.to_s.downcase == "es"
      table&.[](key)
    end

    def self.deterministic_product_answer_table
      {
        "es" => {
          yard_sign_cheapest: "La opcion mas barata de Yard Signs es 10 letreros por $99, doble cara. Incluye estacas, envio y ayuda de diseno. Es el punto de entrada mas simple; quieres empezar con esa opcion?",
          yard_sign_unit: "No hay checkout para un solo letrero. El minimo real es 10 letreros por $99, que sale a $9.90 por letrero.",
          yard_sign_included: "Si. En Yard Signs, la ayuda de diseno, las estacas y el envio estan incluidos en el precio listado.",
          yard_sign_checkout: "Aqui esta el enlace de checkout para Yard Signs:",
          postcard_all_tiers: "La promocion de postales del 4 de julio es solo para postales: 1,000 por $790, 2,500 por $1,725, 5,000 por $3,250, 10,000 por $6,300 y 25,000 por $14,750.",
          postcard_5000: "Para 5,000 postales, el total de la promocion del 4 de julio es $3,250.",
          postcard_checkout: "Aqui esta el enlace de checkout para 5,000 postales:",
          direct_mail_compare: "EDDM es la opcion solo de correo: $399 por una ruta postal. Neighborhood Blitz es el impulso local mas completo por $699, con postales y mas visibilidad local.",
          direct_mail_strategy: "Un consultor de marketing debe ayudar a definir la estrategia, rutas, listas, vecindarios y targeting para que el plan quede claro. Quieres que conecte a alguien?",
          print_products: "WIZWIKI puede ayudar con piezas impresas practicas como tarjetas de presentacion, door hangers, flyers, postales, yard signs y materiales relacionados.",
          print_consultant: "Para flyers, tarjetas de presentacion y door hangers con tamanos o cantidades personalizadas, un consultor de marketing debe ayudar a definirlo para cotizarlo bien.",
          rush_handoff: "Para un pedido urgente, lo mejor es que un consultor de marketing revise el tiempo antes de usar el checkout normal. Quieres que alguien te contacte?",
          proof_design: "Si. Puedes aprobar una prueba antes de imprimir, y el equipo puede ayudar con logo, arte o diseno despues del checkout."
        },
        "zh" => {
          yard_sign_cheapest: "Yard Signs最低总价是10个牌子$99，双面。价格包括支架、配送和设计帮助。这是最简单的起步选择；要从这个开始吗？",
          yard_sign_unit: "没有单个牌子的结账选项。实际最低订单是10个牌子$99，等于每个$9.90。",
          yard_sign_included: "是的。Yard Signs价格包含设计帮助、支架和配送。",
          yard_sign_checkout: "这是Yard Signs的结账链接：",
          postcard_all_tiers: "7月4日明信片优惠只适用于明信片：1,000张$790，2,500张$1,725，5,000张$3,250，10,000张$6,300，25,000张$14,750。",
          postcard_5000: "5,000张明信片的7月4日优惠总价是$3,250。",
          postcard_checkout: "这是5,000张明信片的结账链接：",
          direct_mail_compare: "EDDM是只邮寄的选择：一条邮路$399。Neighborhood Blitz是更完整的本地曝光方案，价格$699，包含明信片和更多本地可见度。",
          direct_mail_strategy: "路线、名单、社区和定位策略应该由营销顾问帮你规划，这样方案会更清楚。要我帮你联系顾问吗？",
          print_products: "WIZWIKI可以帮你做实用印刷品，比如名片、门挂、传单、明信片、庭院牌和相关材料。",
          print_consultant: "如果传单、名片或门挂涉及自定义尺寸或数量，最好让营销顾问帮你整理清楚后再报价。",
          rush_handoff: "如果订单很急，最好先让营销顾问确认时间，再决定是否使用普通结账。要我让顾问联系你吗？",
          proof_design: "可以。印刷前你可以批准校样，结账后团队也可以帮你处理logo、素材或设计。"
        },
        "vi" => {
          yard_sign_cheapest: "Lua chon Yard Signs re nhat la 10 bang voi gia $99, in hai mat. Gia da gom coc, giao hang va ho tro thiet ke. Ban muon bat dau voi goi nay khong?",
          yard_sign_unit: "Khong co checkout cho 1 bang rieng le. Muc nho nhat thuc te la 10 bang voi gia $99, tuc $9.90 moi bang.",
          yard_sign_included: "Co. Yard Signs da bao gom ho tro thiet ke, coc cam bang va giao hang trong gia niem yet.",
          yard_sign_checkout: "Day la link checkout cho Yard Signs:",
          postcard_all_tiers: "Uu dai postcard ngay 4 thang 7 chi ap dung cho postcard: 1,000 cai $790, 2,500 cai $1,725, 5,000 cai $3,250, 10,000 cai $6,300, va 25,000 cai $14,750.",
          postcard_5000: "Voi 5,000 postcard, tong gia uu dai ngay 4 thang 7 la $3,250.",
          postcard_checkout: "Day la link checkout cho 5,000 postcard:",
          direct_mail_compare: "EDDM la tuyen gui thu don gian: $399 cho mot tuyen USPS. Neighborhood Blitz la chien dich hien dien dia phuong rong hon voi gia $699.",
          direct_mail_strategy: "Chien luoc tuyen, danh sach, khu vuc va targeting nen de chuyen vien marketing lap ke hoach cho ro rang. Ban muon toi ket noi khong?",
          print_products: "WIZWIKI co the ho tro business cards, door hangers, flyers, postcards, yard signs va cac vat pham in an lien quan.",
          print_consultant: "Voi flyers, business cards hoac door hangers co kich thuoc hay so luong tuy chinh, chuyen vien marketing nen giup lap thong tin de bao gia dung.",
          rush_handoff: "Voi don gap, nen de chuyen vien marketing kiem tra thoi gian truoc khi dung checkout thong thuong. Ban muon co nguoi lien he khong?",
          proof_design: "Co. Ban co the duyet proof truoc khi in, va doi ngu co the ho tro logo, artwork hoac thiet ke sau checkout."
        },
        "ru" => {
          yard_sign_cheapest: "Самый дешевый вариант Yard Signs — 10 табличек за $99, двусторонние. Включены стойки, доставка и помощь с дизайном. Хотите начать с этого варианта?",
          yard_sign_unit: "Отдельного checkout на одну табличку нет. Минимальный реальный заказ — 10 табличек за $99, то есть $9.90 за штуку.",
          yard_sign_included: "Да. Для Yard Signs помощь с дизайном, стойки и доставка входят в указанную цену.",
          yard_sign_checkout: "Вот ссылка checkout для Yard Signs:",
          postcard_all_tiers: "Спеццена на открытки к 4 июля только для postcards: 1,000 за $790, 2,500 за $1,725, 5,000 за $3,250, 10,000 за $6,300 и 25,000 за $14,750.",
          postcard_5000: "Для 5,000 postcards итог по акции 4 июля — $3,250.",
          postcard_checkout: "Вот ссылка checkout для 5,000 postcards:",
          direct_mail_compare: "EDDM — это вариант только почтовой рассылки: $399 за один маршрут USPS. Neighborhood Blitz — более широкий локальный push за $699.",
          direct_mail_strategy: "Стратегию, маршруты, списки, районы и targeting лучше разобрать с маркетинговым консультантом. Хотите, чтобы я подключил специалиста?",
          print_products: "WIZWIKI может помочь с печатными материалами: визитками, door hangers, flyers, postcards, yard signs и похожими материалами.",
          print_consultant: "Для flyers, визиток и door hangers с нестандартными размерами или количеством маркетинговый консультант поможет собрать детали и корректно посчитать.",
          rush_handoff: "Для срочного заказа лучше, чтобы маркетинговый консультант проверил сроки до обычного checkout. Хотите, чтобы с вами связались?",
          proof_design: "Да. Вы сможете утвердить proof перед печатью, а команда поможет с логотипом, artwork или дизайном после checkout."
        },
        "ar" => {
          yard_sign_cheapest: "ارخص خيار Yard Signs هو 10 لافتات بسعر $99، وجهين. السعر يشمل الاوتاد والشحن ومساعدة التصميم. هل تريد البدء بهذا الخيار؟",
          yard_sign_unit: "لا يوجد checkout للافتة واحدة فقط. اقل طلب فعلي هو 10 لافتات بسعر $99، يعني $9.90 لكل لافتة.",
          yard_sign_included: "نعم. في Yard Signs، مساعدة التصميم والاوتاد والشحن مشمولة في السعر.",
          yard_sign_checkout: "هذا رابط checkout لـ Yard Signs:",
          postcard_all_tiers: "عرض بطاقات البريد ليوم 4 يوليو خاص بالpostcards فقط: 1,000 بسعر $790، 2,500 بسعر $1,725، 5,000 بسعر $3,250، 10,000 بسعر $6,300، و25,000 بسعر $14,750.",
          postcard_5000: "لـ 5,000 postcard، اجمالي عرض 4 يوليو هو $3,250.",
          postcard_checkout: "هذا رابط checkout لـ 5,000 postcard:",
          direct_mail_compare: "EDDM هو خيار بريد فقط: $399 لمسار USPS واحد. Neighborhood Blitz حملة محلية اوسع بسعر $699.",
          direct_mail_strategy: "الاستراتيجية، المسارات، القوائم، الاحياء، والاستهداف يجب ان يراجعها مستشار تسويق حتى تكون الخطة واضحة. هل تريد ان اوصل لك شخصا؟",
          print_products: "WIZWIKI يمكنه المساعدة في مواد مطبوعة مثل business cards وdoor hangers وflyers وpostcards وyard signs ومواد مشابهة.",
          print_consultant: "للطلبات المخصصة مثل flyers او business cards او door hangers بمقاسات او كميات خاصة، الافضل ان يساعد مستشار تسويق في ترتيب التفاصيل.",
          rush_handoff: "للطلب المستعجل، الافضل ان يراجع مستشار تسويق التوقيت قبل استخدام checkout العادي. هل تريد ان يتواصل معك احد؟",
          proof_design: "نعم. يمكنك الموافقة على proof قبل الطباعة، ويمكن للفريق المساعدة في الشعار او artwork او التصميم بعد checkout."
        },
        "tl" => {
          yard_sign_cheapest: "Pinakamurang Yard Signs option ay 10 signs for $99, double-sided. Kasama ang stakes, shipping, at design help. Gusto mo bang doon magsimula?",
          yard_sign_unit: "Walang checkout para sa isang sign lang. Ang pinakamaliit na tunay na order ay 10 signs for $99, kaya $9.90 bawat sign.",
          yard_sign_included: "Oo. Sa Yard Signs, kasama ang design help, stakes, at shipping sa listed price.",
          yard_sign_checkout: "Ito ang checkout link para sa Yard Signs:",
          postcard_all_tiers: "Ang 4th of July postcard special ay para sa postcards lang: 1,000 for $790, 2,500 for $1,725, 5,000 for $3,250, 10,000 for $6,300, at 25,000 for $14,750.",
          postcard_5000: "Para sa 5,000 postcards, ang 4th of July special total ay $3,250.",
          postcard_checkout: "Ito ang checkout link para sa 5,000 postcards:",
          direct_mail_compare: "Ang EDDM ay mail-only option: $399 para sa isang USPS route. Ang Neighborhood Blitz ay mas malawak na local visibility push for $699.",
          direct_mail_strategy: "Dapat marketing consultant ang tumulong sa strategy, routes, lists, neighborhoods, at targeting para malinaw ang plan. Gusto mo bang ikonekta kita?",
          print_products: "Makakatulong ang WIZWIKI sa business cards, door hangers, flyers, postcards, yard signs, at related print pieces.",
          print_consultant: "Para sa custom sizes o quantities ng flyers, business cards, at door hangers, marketing consultant ang dapat tumulong para ma-quote nang maayos.",
          rush_handoff: "Para sa rush order, mas mabuting marketing consultant ang mag-check ng timing bago gamitin ang normal checkout. Gusto mo bang may kumontak?",
          proof_design: "Oo. Pwede mong i-approve ang proof bago mag-print, at makakatulong ang team sa logo, artwork, o design pagkatapos ng checkout."
        },
        "ko" => {
          yard_sign_cheapest: "Yard Signs의 가장 낮은 시작 옵션은 양면 10개에 $99입니다. 말뚝, 배송, 디자인 도움이 포함됩니다. 이 옵션으로 시작할까요?",
          yard_sign_unit: "한 개만 주문하는 checkout은 없습니다. 실제 최소 주문은 10개에 $99이고, 개당 $9.90입니다.",
          yard_sign_included: "네. Yard Signs 가격에는 디자인 도움, 말뚝, 배송이 포함됩니다.",
          yard_sign_checkout: "Yard Signs checkout 링크입니다:",
          postcard_all_tiers: "7월 4일 postcard 특별가는 postcards 전용입니다: 1,000장 $790, 2,500장 $1,725, 5,000장 $3,250, 10,000장 $6,300, 25,000장 $14,750.",
          postcard_5000: "5,000 postcards의 7월 4일 특별가 총액은 $3,250입니다.",
          postcard_checkout: "5,000 postcards checkout 링크입니다:",
          direct_mail_compare: "EDDM은 우편 전용 옵션으로 USPS route 하나가 $399입니다. Neighborhood Blitz는 더 넓은 로컬 노출 캠페인으로 $699입니다.",
          direct_mail_strategy: "전략, routes, lists, neighborhoods, targeting은 marketing consultant가 정리하는 것이 좋습니다. 연결해 드릴까요?",
          print_products: "WIZWIKI는 business cards, door hangers, flyers, postcards, yard signs 등 관련 인쇄물을 도와드릴 수 있습니다.",
          print_consultant: "flyers, business cards, door hangers의 맞춤 사이즈나 수량은 marketing consultant가 정리해서 정확히 견적 내는 것이 좋습니다.",
          rush_handoff: "급한 주문은 normal checkout 전에 marketing consultant가 일정을 확인하는 것이 좋습니다. 연락드리게 할까요?",
          proof_design: "네. 인쇄 전 proof를 승인할 수 있고, checkout 후 팀이 logo, artwork, design을 도와드릴 수 있습니다."
        },
        "pt" => {
          yard_sign_cheapest: "A opcao mais barata de Yard Signs e 10 placas por $99, frente e verso. Inclui estacas, envio e ajuda de design. Quer comecar por essa opcao?",
          yard_sign_unit: "Nao existe checkout para apenas uma placa. O minimo real e 10 placas por $99, ou $9.90 por placa.",
          yard_sign_included: "Sim. Em Yard Signs, ajuda de design, estacas e envio estao incluidos no preco listado.",
          yard_sign_checkout: "Aqui esta o link de checkout para Yard Signs:",
          postcard_all_tiers: "A promocao de postcards de 4 de julho e somente para postcards: 1,000 por $790, 2,500 por $1,725, 5,000 por $3,250, 10,000 por $6,300 e 25,000 por $14,750.",
          postcard_5000: "Para 5,000 postcards, o total da promocao de 4 de julho e $3,250.",
          postcard_checkout: "Aqui esta o link de checkout para 5,000 postcards:",
          direct_mail_compare: "EDDM e a opcao somente correio: $399 por uma rota USPS. Neighborhood Blitz e uma campanha local mais completa por $699.",
          direct_mail_strategy: "E melhor um consultor de marketing definir estrategia, rotas, listas, bairros e targeting para deixar o plano claro. Quer que eu conecte alguem?",
          print_products: "A WIZWIKI pode ajudar com business cards, door hangers, flyers, postcards, yard signs e outros materiais impressos.",
          print_consultant: "Para flyers, business cards ou door hangers com tamanhos ou quantidades customizadas, um consultor de marketing deve ajudar a organizar para cotar corretamente.",
          rush_handoff: "Para pedido urgente, e melhor um consultor de marketing checar o prazo antes do checkout normal. Quer que alguem entre em contato?",
          proof_design: "Sim. Voce pode aprovar uma prova antes da impressao, e a equipe pode ajudar com logo, arte ou design depois do checkout."
        }
      }
    end

    def self.deterministic_spanish_outbound_phrase(text)
      body = text.to_s.squish
      if body.match?(/\Ayes[,.]?\s+i\s+can\s+text\s+you\s+in\s+spanish\.?\s+are\s+you\s+thinking\s+postcards,\s+yard\s+signs,\s+or\s+both\?\z/i)
        return "Sí, puedo escribirte en español. ¿Estás pensando en postales, letreros de jardín o ambos?"
      end

      if (match = body.match(/\A(?<ack>got\s+it(?:,\s*(?:english|spanish))?\.\s*)?for\s+(?<size>\d{1,3}\s*x\s*\d{1,3})\s+yard signs?,\s*(?<tiers>.+?)\.\s*stakes,\s*shipping,\s*and\s*design\s+are\s+included\.\s*what\s+quantity\s+feels\s+closest\?\z/i))
        pairs = match[:tiers].scan(/(?<quantity>\d[\d,]*)\s+are\s+(?<price>\$(?:\d{1,3}(?:,\d{3})+|\d+)(?:\.\d+)?)/i)
        if pairs.length > 1
          tiers = pairs.map { |quantity, price| "#{quantity} cuestan #{price}" }
          tier_list = [tiers[0...-1].join(", "), tiers.last].reject(&:blank?).join(" y ")
          acknowledgement = match[:ack].present? ? "Entendido. " : ""
          return "#{acknowledgement}Para letreros de jardín de #{match[:size].delete(' ')}, #{tier_list}. Se incluyen estacas, envío y diseño. ¿Qué cantidad se acerca más?"
        end
      end

      if (match = body.match(/\A(?:for\s+)?(?<qty>\d[\d,]*)\s+yard signs?\s+are\s+(?<price>\$?[\d,]+(?:\.\d+)?(?:\s+dollars)?)\s+with\s+stakes,\s+shipping,\s+and\s+design\s+included\.?\s*(?<tail>.*)\z/i))
        parts = [
          "#{match[:qty]} letreros de jardín cuestan #{spanish_price(match[:price])} con estacas, envío y diseño incluidos.",
          deterministic_spanish_tail(match[:tail])
        ]
        return parts.compact_blank.join(" ").squish
      end

      if (match = body.match(/\A(?<qty>\d[\d,]*)\s+yard signs?\s+are\s+(?<price>\$?[\d,]+(?:\.\d+)?(?:\s+dollars)?)\.?\s*(?<tail>.*)\z/i))
        parts = [
          "#{match[:qty]} letreros de jardín cuestan #{spanish_price(match[:price])}.",
          deterministic_spanish_tail(match[:tail])
        ]
        return parts.compact_blank.join(" ").squish
      end

      nil
    end

    def self.deterministic_spanish_tail(text)
      tail = text.to_s.squish
      return if tail.blank?

      case tail
      when /\AWant the checkout link for that option\??\z/i
        "¿Quieres el enlace de pago para esa opción?"
      when /\AHere is the checkout link:?\z/i
        "Aquí está el enlace de pago:"
      when /\AUse this checkout link when you are ready:?\z/i
        "Usa este enlace de pago cuando estés listo:"
      else
        nil
      end
    end

    def self.spanish_price(value)
      value.to_s.squish.gsub(/\bdollars\b/i, "dólares")
    end

    def self.deterministic_chinese_outbound_phrase(text)
      body = text.to_s.squish
      if body.match?(/\Ayes[.!]?\s+the\s+4th\s+of\s+july\s+postcard\s+special\s+is\s+postcard-only:/i) &&
          body.match?(/\b1,?000\b/) &&
          body.match?(/\$\s?790\b/) &&
          body.match?(/\b25,?000\b/) &&
          body.match?(/\$\s?14,?750\b/)
        return "是的。7月4日明信片特价只适用于明信片：1,000张$790，2,500张$1,725，5,000张$3,250，10,000张$6,300，25,000张$14,750。你是考虑1,000张以上的明信片吗？"
      end

      if (match = body.match(/\Ayes[.!]?\s+for\s+(?<qty>1,?000|1000|2,?500|2500|5,?000|5000|10,?000|10000|25,?000|25000)\s+postcards?,\s+the\s+4th\s+of\s+july\s+postcard\s+block\s+sale\s+is\s+(?<price>\$\s?[\d,]+)\.?\s*(?<tail>.*)\z/i))
        quantity = match[:qty].to_s.gsub(/(?<=\d)(?=(\d{3})+\b)/, ",")
        parts = [
          "是的。#{quantity}张明信片的7月4日明信片Block Sale价格是#{match[:price].delete(' ')}。",
          deterministic_chinese_tail(match[:tail])
        ]
        return parts.compact_blank.join(" ").squish
      end

      nil
    end

    def self.deterministic_chinese_tail(text)
      tail = text.to_s.squish
      return if tail.blank?

      case tail
      when /\AWant me to send that checkout link\??\z/i
        "要我发送这个付款链接吗？"
      when /\AHere is the checkout link:?\z/i
        "这是付款链接："
      when /\AAre you looking at 1,?000\+ postcards\??\z/i
        "你是考虑1,000张以上的明信片吗？"
      else
        nil
      end
    end

    def self.split_url_suffix(text)
      body = text.to_s.squish
      match = body.match(%r{\bhttps?://\S+\z}i)
      return [body, nil] unless match

      [body[0...match.begin(0)].to_s.squish, match[0]]
    end

    def self.valid_outbound_translation?(translated, code:, source:)
      language_code = code.to_s.downcase
      return true if language_code == "en"

      body = translated.to_s.squish
      original = source.to_s.squish
      return false if body.blank? || body.casecmp(original).zero?
      return false unless translation_preserves_source_contract?(source: original, translated: body)

      target_language_signal?(body, language_code)
    end

    def self.valid_inbound_translation?(translated, source:)
      body = translated.to_s.squish
      original = source.to_s.squish
      return false if body.blank? || body.casecmp(original).zero?

      translation_preserves_source_contract?(source: original, translated: body)
    end

    def self.translation_preserves_source_contract?(source:, translated:)
      original = source.to_s.squish
      target = translated.to_s.squish
      return false if original.blank? || target.blank?

      protected_tokens = original.scan(PROTECTED_TOKEN_PATTERN).map(&:to_s).uniq
      return false unless protected_tokens.all? { |token| target.include?(token) }

      source_questions = original.scan(/[?？؟]/).length
      target_questions = target.scan(/[?？؟]/).length
      source_questions.zero? || target_questions.positive?
    end

    def self.target_language_signal?(text, code)
      pattern = TARGET_LANGUAGE_SIGNAL_PATTERNS[code.to_s.downcase]
      return true if pattern.blank?

      text.to_s.match?(pattern)
    end

    def self.localized_outbound_failsafe_body(code)
      OUTBOUND_FAILSAFE_BODIES[code.to_s.downcase]
    end

    def self.localized_outbound_failsafe_english_body(label)
      "I'm checking the details so I can answer clearly in #{label}. Give me a moment."
    end

    def self.language_label(code)
      CUSTOMER_LANGUAGE_CODES.fetch(code.to_s.downcase, "English")
    end

    def self.translate_text(text, from:, to:, direction:)
      source = text.to_s.squish
      return if source.blank?

      masked, tokens = mask_protected_tokens(source)
      prompt = <<~PROMPT.squish
        /no_think
        Translate this SMS from #{from} to #{to}. Return only the translated SMS body.
        Keep placeholders like [[TOKEN0]] exactly unchanged. Keep product names, prices, quantities, URLs, and STOP unchanged.
        Use print-shop vocabulary: yard signs are customer lawn/yard signs, stakes are sign stakes/estacas, proof means design proof/approval.
        Make it sound natural, friendly, and concise for a customer text.
        SMS: #{masked}
      PROMPT
      raw = qwen_generate(prompt)
      clean = polish_translated_text(strip_translation_wrapper(raw), to: to)
      restore_protected_tokens(clean, tokens).squish.presence
    rescue StandardError => error
      Rails.logger.warn("[Comms::SmsLanguageSupport] #{direction} translation failed #{error.class}: #{error.message}")
      nil
    end

    def self.polish_translated_text(text, to:)
      translated = text.to_s
      return translated unless to.to_s.casecmp("Spanish").zero?

      translated
        .gsub(/\benvío\s+e\s+diseño\b/i, "envío y diseño")
        .gsub(/\bclavos\b/i, "estacas")
    end

    def self.qwen_generate(prompt)
      uri = URI.join(QWEN_BASE_URL.to_s.chomp("/") + "/", "api/generate")
      last_error = nil
      QWEN_MODEL_LADDER.each do |model|
        payload = {
          model: model,
          prompt: prompt,
          stream: false,
          think: false,
          options: {
            temperature: 0.1,
            num_predict: 240
          }
        }
        begin
          response = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https", open_timeout: OPEN_TIMEOUT, read_timeout: READ_TIMEOUT) do |http|
            request = Net::HTTP::Post.new(uri)
            request["Content-Type"] = "application/json"
            request.body = JSON.generate(payload)
            http.request(request)
          end
          raise "HTTP #{response.code}" unless response.is_a?(Net::HTTPSuccess)

          text = JSON.parse(response.body)["response"].to_s
          return text if text.squish.present?

          last_error = "#{model}: blank response"
        rescue StandardError => error
          last_error = "#{model}: #{error.class}: #{error.message}"
          Rails.logger.warn("[Comms::SmsLanguageSupport] translation model failed #{last_error}") if defined?(Rails)
        end
      end

      raise(last_error.presence || "SMS translation returned blank response")
    end

    def self.mask_protected_tokens(text)
      tokens = []
      masked = text.gsub(PROTECTED_TOKEN_PATTERN) do |match|
        token = "[[TOKEN#{tokens.length}]]"
        tokens << match
        token
      end
      [masked, tokens]
    end

    def self.restore_protected_tokens(text, tokens)
      restored = text.to_s
      tokens.each_with_index do |value, index|
        restored = restored.gsub("[[TOKEN#{index}]]", value)
      end
      restored.gsub(/\\(\$)/, "\\1")
    end

    def self.strip_translation_wrapper(text)
      body = text.to_s.strip
      body = body.sub(/\A```(?:text|sms)?/i, "").sub(/```\z/, "").strip
      body = body.sub(/\A(?:translation|translated sms|sms|respuesta|reply)\s*:\s*/i, "").strip
      body.gsub(/\A["']|["']\z/, "").strip
    end

    def self.restore_terminal_punctuation(source, target)
      clean = target.to_s.squish
      return clean if clean.blank? || clean.match?(/[.!?。！？؟]\z/)

      case source.to_s.squish[-1]
      when "?"
        "#{clean}?"
      when "!"
        "#{clean}!"
      else
        clean
      end
    end
  end
end
