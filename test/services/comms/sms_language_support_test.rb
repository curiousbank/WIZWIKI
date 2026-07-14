require "active_support/core_ext/object/blank"
require "active_support/core_ext/enumerable"
require "active_support/core_ext/string/filters"
require "minitest/autorun"
require "ostruct"
require_relative "../../../app/services/comms/sms_language_support"

module Comms
  class SmsLanguageSupportTest < Minitest::Test
    def test_support_stays_scoped_to_original_multilingual_test_languages
      assert_equal %w[ar en es ko pt ru tl vi zh], SmsLanguageSupport::CUSTOMER_LANGUAGE_CODES.keys.sort
    end

    def test_detects_spanglish_typo_from_sample_contact_thread
      detection = SmsLanguageSupport.detect_language("Yo quero signs por favor")

      assert_equal "es", detection.fetch(:code)
      assert_equal "Spanish", detection.fetch(:label)
    end

    def test_normalizes_spanglish_product_preference_before_model_translation
      assert_equal "I want yard signs please.", SmsLanguageSupport.deterministic_inbound_translation("Me prefero signs por favor", code: "es")
      assert_equal "I want yard signs please.", SmsLanguageSupport.deterministic_inbound_translation("Yo quero signs por favor", code: "es")
    end

    def test_normalizes_spanglish_price_question
      assert_equal "How much are yard signs?", SmsLanguageSupport.deterministic_inbound_translation("cuanto cuestan signs?", code: "es")
    end

    def test_normalizes_spanish_multilingual_dojo_followups
      assert_equal "What is the cheapest option to start?", SmsLanguageSupport.deterministic_inbound_translation("¿Cuál es la opción más barata para empezar?", code: "es")
      assert_equal "How much would each yard sign cost?", SmsLanguageSupport.deterministic_inbound_translation("¿Cuánto saldría cada letrero si solo quiero saber el costo de uno?", code: "es")
      assert_equal "Does it include design, stakes, and shipping?", SmsLanguageSupport.deterministic_inbound_translation("¿Incluye diseño, estacas y envío?", code: "es")
      assert_equal "Send me the link for 10 yard signs.", SmsLanguageSupport.deterministic_inbound_translation("Mándame el enlace para 10 letreros.", code: "es")
    end

    def test_normalizes_static_multilingual_dojo_turns_before_model_translation
      assert_equal "What is the total for 5,000 postcards?", SmsLanguageSupport.deterministic_inbound_translation("如果我要 5,000 张，总价是多少？", code: "zh")
      assert_equal "Yes, please have a marketing consultant contact me.", SmsLanguageSupport.deterministic_inbound_translation("Được, hãy cho chuyên viên marketing liên hệ với tôi.", code: "vi")
      assert_equal "Can a marketing consultant help choose?", SmsLanguageSupport.deterministic_inbound_translation("Может ли маркетинговый консультант помочь выбрать?", code: "ru")
      assert_equal "What is the difference between EDDM and Neighborhood Blitz?", SmsLanguageSupport.deterministic_inbound_translation("ما الفرق بين EDDM و Neighborhood Blitz؟", code: "ar")
      assert_equal "If I order 1,000 postcards, is that part of the 4th of July Block Sale?", SmsLanguageSupport.deterministic_inbound_translation("Se eu fizer 1.000 postais, isso entra na promoção 4th of July Block Sale?", code: "pt")
    end

    def test_detects_and_normalizes_ambos_reply
      detection = SmsLanguageSupport.detect_language("Ambos")

      assert_equal "es", detection.fetch(:code)
      assert_equal "Both.", SmsLanguageSupport.deterministic_inbound_translation("Ambos", code: "es")
    end

    def test_detects_plain_spanish_preference_reply
      detection = SmsLanguageSupport.detect_language("Spanish please")

      assert_equal "es", detection.fetch(:code)
      assert_equal "Spanish", detection.fetch(:label)
    end

    def test_normalizes_plain_spanish_preference_before_model_translation
      assert_equal "I prefer Spanish.", SmsLanguageSupport.deterministic_inbound_translation("Si yo prefiero espanol", code: "es")
      assert_equal "I prefer Spanish.", SmsLanguageSupport.deterministic_inbound_translation("Prefiero español", code: "es")
      assert_equal "I prefer Spanish.", SmsLanguageSupport.deterministic_inbound_translation("Espanol por favor", code: "es")
    end

    def test_explicit_english_preference_clears_prior_spanish_state
      stage = OpenStruct.new(metadata: {
        "sms_language_preferred_code" => "es",
        "sms_language_preferred_label" => "Spanish"
      })

      result = SmsLanguageSupport.prepare_inbound_body(stage: stage, metadata: stage.metadata, body: "English please")

      assert_equal "I prefer English.", result.body
      assert_equal "en", result.metadata["sms_language_preferred_code"]
      assert_equal "English", result.metadata["sms_language_preferred_label"]
    end

    def test_normalizes_supported_language_preference_replies_before_model_translation
      examples = {
        "es" => ["Si yo prefiero espanol", "Spanish"],
        "zh" => ["请用中文回复", "Chinese"],
        "vi" => ["Tiếng Việt please", "Vietnamese"],
        "ru" => ["пожалуйста, отвечайте по-русски", "Russian"],
        "ar" => ["أفضّل العربية", "Arabic"],
        "tl" => ["Tagalog sana ang sagot", "Tagalog"],
        "ko" => ["한국어로 답해 주세요", "Korean"],
        "pt" => ["Prefiro português", "Portuguese"]
      }

      examples.each do |code, (source, label)|
        assert_equal "I prefer #{label}.", SmsLanguageSupport.deterministic_inbound_translation(source, code: code)
      end
    end

    def test_preference_notice_lists_short_language_menu
      notice = SmsLanguageSupport.preference_notice_body

      assert_includes notice, "Prefer another language?"
      assert_includes notice, "更喜欢其他语言？"
      assert_includes notice, "Русский"
      assert_includes notice, "العربية"
      assert_includes notice, "Português"
    end

    def test_organization_setting_disables_language_processing
      organization = OpenStruct.new(settings: {
        SmsLanguageSupport::SETTINGS_KEY => { "enabled" => false }
      })
      stage = OpenStruct.new(
        organization: organization,
        metadata: {
          "sms_language_preferred_code" => "es",
          "sms_language_preferred_label" => "Spanish"
        }
      )

      inbound = SmsLanguageSupport.prepare_inbound_body(stage: stage, metadata: stage.metadata, body: "Prefiero español")
      outbound = SmsLanguageSupport.prepare_outbound_body(stage: stage, body: "Yes, I can text you in Spanish. Are you thinking postcards, yard signs, or both?")

      assert_equal "Prefiero español", inbound.body
      assert_equal({}, inbound.metadata)
      assert_equal "Yes, I can text you in Spanish. Are you thinking postcards, yard signs, or both?", outbound.body
      assert_equal({}, outbound.metadata)
      refute SmsLanguageSupport.should_send_preference_notice?(
        {
          "sms_thread" => [
            {
              "channel" => "sms",
              "direction" => "outbound",
              "status" => "sent",
              "body" => "Hi Sample Contact, I'm Thumper from WIZWIKI Marketing."
            }
          ]
        },
        stage: stage
      )
    end

    def test_organization_setting_can_enable_language_processing
      organization = OpenStruct.new(settings: {
        SmsLanguageSupport::SETTINGS_KEY => { "enabled" => true }
      })
      stage = OpenStruct.new(organization: organization, metadata: {})

      result = SmsLanguageSupport.prepare_inbound_body(stage: stage, metadata: stage.metadata, body: "Prefiero español")

      assert_equal "I prefer Spanish.", result.body
      assert_equal "es", result.language_code
      assert SmsLanguageSupport.enabled_for?(stage: stage)
    end

    def test_detects_russian_language_name_and_cyrillic_message
      name_detection = SmsLanguageSupport.detect_language("Русский")
      message_detection = SmsLanguageSupport.detect_language("Мне нужны таблички, пожалуйста")

      assert_equal "ru", name_detection.fetch(:code)
      assert_equal "Russian", name_detection.fetch(:label)
      assert_equal "ru", message_detection.fetch(:code)
      assert_equal "Russian", message_detection.fetch(:label)
    end

    def test_detects_supported_language_name_replies
      assert_equal "vi", SmsLanguageSupport.detect_language("Tiếng Việt please").fetch(:code)
      assert_equal "ar", SmsLanguageSupport.detect_language("العربية").fetch(:code)
      assert_equal "tl", SmsLanguageSupport.detect_language("Tagalog").fetch(:code)
      assert_equal "ko", SmsLanguageSupport.detect_language("한국어").fetch(:code)
      assert_equal "pt", SmsLanguageSupport.detect_language("Português").fetch(:code)
    end

    def test_masks_prices_and_dimensions_for_translation
      masked, tokens = SmsLanguageSupport.mask_protected_tokens("For 18x24 yard signs, 10 are $99.")

      assert_includes tokens, "18x24"
      assert_includes tokens, "10"
      assert_includes tokens, "$99"
      assert_equal "Para 18x24, 10 cuestan $99.", SmsLanguageSupport.restore_protected_tokens("Para [[TOKEN0]], [[TOKEN1]] cuestan \\[[TOKEN2]].", tokens)
      assert_includes masked, "[[TOKEN0]]"
      assert_includes masked, "[[TOKEN1]]"
      assert_includes masked, "[[TOKEN2]]"
    end

    def test_deterministic_spanish_outbound_yard_sign_pricing_with_link
      body = "100 yard signs are $399 with stakes, shipping, and design included. Want the checkout link for that option? https://shop.example.invalid/products/24x18-yard-signs-sample_owner"
      translated = SmsLanguageSupport.deterministic_outbound_translation(body, code: "es")

      assert_equal(
        "100 letreros de jardín cuestan $399 con estacas, envío y diseño incluidos. ¿Quieres el enlace de pago para esa opción? https://shop.example.invalid/products/24x18-yard-signs-sample_owner",
        translated
      )
    end

    def test_compound_price_ladder_bypasses_lossy_phrasebook_and_preserves_contract
      source = "Got it, Spanish. For 18x24 yard signs, 10 are $99, 20 are $159, 50 are $249, 100 are $399, 250 are $899, 500 are $1,699, and 1,000 are $3,349. Stakes, shipping, and design are included. What quantity feels closest?"
      translated = "Entendido. Para letreros de jardín de 18x24, 10 cuestan $99, 20 cuestan $159, 50 cuestan $249, 100 cuestan $399, 250 cuestan $899, 500 cuestan $1,699 y 1,000 cuestan $3,349. Se incluyen estacas, envío y diseño. ¿Qué cantidad se acerca más?"
      stage = OpenStruct.new(metadata: {
        "sms_language_preferred_code" => "es",
        "sms_language_preferred_label" => "Spanish"
      })

      assert_equal translated, SmsLanguageSupport.deterministic_outbound_translation(source, code: "es")
      refute SmsLanguageSupport.valid_outbound_translation?("Sí. El diseño, las estacas y el envío están incluidos.", code: "es", source: source)

      result = SmsLanguageSupport.prepare_outbound_body(stage: stage, body: source)

      assert_equal translated, result.body
      assert_equal "deterministic/sms_phrasebook", result.event["translation_provider"]
      assert result.translated
      %w[$99 $159 $249 $399 $899 $1,699 $3,349].each { |price| assert_includes result.body, price }
      %w[10 20 50 100 250 500 1,000].each { |quantity| assert_includes result.body, quantity }
      assert_match(/[?¿]/, result.body)
    end

    def test_rejects_lossy_model_translation_before_it_enters_rag_context
      organization = OpenStruct.new(settings: {
        SmsLanguageSupport::SETTINGS_KEY => { "enabled" => true }
      })
      stage = OpenStruct.new(organization: organization, metadata: {})
      source = "Necesito 10 folletos y mi presupuesto es $99. ¿Qué recomienda?"

      with_translation_stub("I need brochures. What do you recommend?") do
        result = SmsLanguageSupport.prepare_inbound_body(stage: stage, metadata: stage.metadata, body: source)

        assert_equal source, result.body
        assert_equal "translation_rejected_incomplete", result.error
        assert_equal "es", result.language_code
        refute result.translated
      end
    end

    def test_deterministic_spanish_outbound_language_confirmation
      body = "Yes, I can text you in Spanish. Are you thinking postcards, yard signs, or both?"
      translated = SmsLanguageSupport.deterministic_outbound_translation(body, code: "es")

      assert_equal "Sí, puedo escribirte en español. ¿Estás pensando en postales, letreros de jardín o ambos?", translated
    end

    def test_deterministic_language_confirmation_for_supported_outbound_languages
      expected = {
        "es" => ["Spanish", "Sí, puedo escribirte en español. ¿Estás pensando en postales, letreros de jardín o ambos?"],
        "zh" => ["Chinese", "可以，我可以用中文给你发短信。你是在考虑明信片、庭院标牌，还是两者都要？"],
        "vi" => ["Vietnamese", "Có, tôi có thể nhắn tin cho bạn bằng tiếng Việt. Bạn đang nghĩ đến bưu thiếp, bảng yard sign, hay cả hai?"],
        "ru" => ["Russian", "Да, я могу писать вам по-русски. Вы думаете о почтовых открытках, табличках для двора или о том и другом?"],
        "ar" => ["Arabic", "نعم، يمكنني مراسلتك بالعربية. هل تفكر في بطاقات بريدية، لافتات للحديقة، أم الاثنين؟"],
        "tl" => ["Tagalog", "Oo, puwede kitang i-text sa Tagalog. Postcards, yard signs, o pareho ba ang iniisip mo?"],
        "ko" => ["Korean", "네, 한국어로 문자드릴 수 있어요. 엽서, 야드 사인, 아니면 둘 다 생각 중이신가요?"],
        "pt" => ["Portuguese", "Sim, posso te mandar mensagem em português. Você está pensando em cartões postais, placas de jardim ou ambos?"]
      }

      expected.each do |code, (label, translation)|
        body = "Yes, I can text you in #{label}. Are you thinking postcards, yard signs, or both?"
        assert_equal translation, SmsLanguageSupport.deterministic_outbound_translation(body, code: code)
      end
    end

    def test_deterministic_russian_outbound_keeps_broad_print_product_answers
      body = "Yes. WIZWIKI can help with business cards, door hangers, flyers, postcards, yard signs, rack cards, and related campaign materials. If it gets custom, a marketing consultant can help map it out."
      translated = SmsLanguageSupport.deterministic_outbound_translation(body, code: "ru")

      assert_match(/печатными материалами/i, translated)
      assert_match(/визитками/i, translated)
      refute_match(/нестандартными размерами|корректно посчитать/i, translated)
    end

    def test_deterministic_russian_outbound_print_products_win_over_yard_sign_included
      body = "Yep, we can help with yard signs. For the yard-sign deal, stakes, shipping, and design are included. If you want cards or flyers, we can help with those too."
      translated = SmsLanguageSupport.deterministic_outbound_translation(body, code: "ru")

      assert_match(/печатными материалами/i, translated)
      refute_match(/стойки и доставка входят/i, translated)
    end

    def test_rejects_outbound_translation_that_is_still_english
      source = "A teammate can follow up with the next step soon."

      refute SmsLanguageSupport.valid_outbound_translation?(source, code: "vi", source: source)
      refute SmsLanguageSupport.valid_outbound_translation?("Yes, we can help with yard signs.", code: "ru", source: source)
      assert SmsLanguageSupport.valid_outbound_translation?("Да, мы можем помочь с печатными материалами.", code: "ru", source: source)
      assert SmsLanguageSupport.valid_outbound_translation?("يمكننا مساعدتك في البريد المباشر.", code: "ar", source: source)
    end

    def test_non_english_outbound_does_not_fall_back_to_english_when_translation_times_out
      stage = OpenStruct.new(metadata: {
        "sms_language_preferred_code" => "vi",
        "sms_language_preferred_label" => "Vietnamese"
      })
      source = "A teammate can follow up with the next step soon."

      with_translation_stub(nil) do
        result = SmsLanguageSupport.prepare_outbound_body(stage: stage, body: source)

        refute_equal source, result.body
        assert_match(/tiếng Việt/i, result.body)
        assert_equal "vi", result.language_code
        assert_equal "translation_unavailable", result.error
        assert_equal "I'm checking the details so I can answer clearly in Vietnamese. Give me a moment.", result.event["english_body"]
        assert_equal source, result.event["translation_source_english_body"]
        assert_equal result.event["english_body"], result.metadata["sms_language_last_outbound_english"]
        assert_equal "localized/failsafe", result.event["translation_provider"]
        assert_equal true, result.event["language_failsafe"]
      end
    end

    def test_wrong_language_outbound_translation_gets_localized_failsafe
      stage = OpenStruct.new(metadata: {
        "sms_language_preferred_code" => "ru",
        "sms_language_preferred_label" => "Russian"
      })
      source = "Yes, we can help with the next step."

      with_translation_stub("Yes, we can help with the next step.") do
        result = SmsLanguageSupport.prepare_outbound_body(stage: stage, body: source)

        refute_equal source, result.body
        assert_match(/по-русски/i, result.body)
        assert_equal "translation_rejected_wrong_language", result.error
        assert_equal "I'm checking the details so I can answer clearly in Russian. Give me a moment.", result.event["english_body"]
        assert_equal source, result.event["translation_source_english_body"]
        assert_equal true, result.event["language_failsafe"]
      end
    end

    private

    def with_translation_stub(value)
      original = SmsLanguageSupport.method(:translate_text)
      SmsLanguageSupport.define_singleton_method(:translate_text) { |*| value }
      yield
    ensure
      SmsLanguageSupport.define_singleton_method(:translate_text, original)
    end
  end
end
