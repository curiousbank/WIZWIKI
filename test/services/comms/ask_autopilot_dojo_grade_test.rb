require "test_helper"
require "ostruct"

module Comms
  class AskAutopilotDojoGradeTest < ActiveSupport::TestCase
    test "deterministic dojo grade does not pass a price question non-answer" do
      grade = AskAutopilotTest.send(
        :deterministic_dojo_grade,
        OpenStruct.new(metadata: {}),
        { "body" => "how much for yard signs?" },
        "What quantity do you need?",
        { "sms_quality_gate" => "passed", "provider" => "test", "model" => "test" }
      )

      assert_equal "REVIEW", grade["verdict"]
      assert_operator grade["score"], :<, 85
      assert grade["findings"].any? { |finding| finding.match?(/price/i) }
    end

    test "deterministic dojo grade reserves perfect scores for more than clean answers" do
      grade = AskAutopilotTest.send(
        :deterministic_dojo_grade,
        OpenStruct.new(metadata: {}),
        { "body" => "$100 bucks, what can I get for yard signs?" },
        "For about $100, use the 10-sign Yard Signs tier at $99. If you want more signs, the next listed tier is 20 signs at $159.",
        { "sms_quality_gate" => "passed", "provider" => "test", "model" => "test" }
      )

      assert_equal "PASS", grade["verdict"]
      assert_operator grade["score"], :<, 100
    end

    test "required dojo conversations cover live sms readiness scenarios" do
      ids = AskAutopilotTest.send(:owner_yard_sign_conversation_scenarios).map { |scenario| scenario[:id].to_s }

      assert_equal(
        %w[
          live_double_text_before_reply
          live_triple_text_before_reply
          live_customer_changes_lanes_mid_thread
          live_two_questions_one_message
          live_other_print_products
          live_other_print_product_details
          live_messy_print_consultant_handoff
          live_direct_mail_strategy_boundary
          live_rush_no_normal_checkout
          live_proof_design_direct_not_canned
        ],
        ids
      )
    end

    test "review all dojo scenario includes final human handoff complaint" do
      scenario = AskAutopilotTest.send(:dojo_conversation_by_id, "review_all")

      assert scenario.present?
      assert_equal "Review all", scenario[:title]
      assert_includes scenario[:checks].map(&:to_s), "review_all_human_handoff"
      assert_includes scenario[:checks].map(&:to_s), "review_all_delayed_multi_texts"
      flattened_turns = scenario[:turns].flat_map { |turn| turn.is_a?(Hash) ? Array(turn[:messages]) : turn }.map(&:to_s)
      assert flattened_turns.any? { |turn| turn.match?(/taking too long.*talke ot a human/i) }
      assert_equal [3, 2, 3, 2, 2], scenario[:turns].map { |turn| Array(turn[:messages]).length }
      assert scenario[:turns].all? { |turn| turn[:delay_seconds] == 25 }
    end

    test "review all and sample_contact guidance run only the Sample Contact conversation scenario" do
      assert_empty AskAutopilotTest.send(:dojo_scenarios, "review all")

      scenarios = AskAutopilotTest.send(:dojo_conversation_scenarios, "review all")
      assert_equal ["review_all"], scenarios.map { |scenario| scenario[:id].to_s }

      typo_scenarios = AskAutopilotTest.send(:dojo_conversation_scenarios, "revierdw all")
      assert_equal ["review_all"], typo_scenarios.map { |scenario| scenario[:id].to_s }

      assert_empty AskAutopilotTest.send(:dojo_scenarios, "sample_contact")
      sample_contact_scenarios = AskAutopilotTest.send(:dojo_conversation_scenarios, "sample_contact")
      assert_equal ["review_all"], sample_contact_scenarios.map { |scenario| scenario[:id].to_s }
    end

    test "dojo guidance separates Sample Owner default Sample Contact review and multilingual suites" do
      owner_ids = AskAutopilotTest.send(:owner_yard_sign_conversation_scenarios).map { |scenario| scenario[:id].to_s }

      assert_equal 10, owner_ids.length
      refute_includes owner_ids, "review_all"
      assert_equal owner_ids, AskAutopilotTest.send(:dojo_conversation_scenarios, nil).map { |scenario| scenario[:id].to_s }
      assert_equal owner_ids, AskAutopilotTest.send(:dojo_conversation_scenarios, "sample_owner").map { |scenario| scenario[:id].to_s }
      assert_equal ["review_all"], AskAutopilotTest.send(:dojo_conversation_scenarios, "sample_contact").map { |scenario| scenario[:id].to_s }
      assert_equal 8, AskAutopilotTest.send(:dojo_conversation_scenarios, "multilingual").length
    end

    test "review all grade requires delayed double and triple message stacks" do
      conversation = {
        title: "Review all",
        checks: %w[review_all_delayed_multi_texts]
      }
      turn_summaries = [
        { "turn" => 1, "customer_message_count" => 3, "customer_delay_seconds" => 10, "answer" => "Postcards are available." },
        { "turn" => 2, "customer_message_count" => 2, "customer_delay_seconds" => 10, "answer" => "A consultant can help." }
      ]

      grade = AskAutopilotTest.send(:deterministic_dojo_conversation_grade, conversation, turn_summaries)

      assert_equal "REVIEW", grade["verdict"]
      assert grade["findings"].any? { |finding| finding.match?(/25-second|delayed multi-text/i) }

      turn_summaries.each { |turn| turn["customer_delay_seconds"] = 25 }
      grade = AskAutopilotTest.send(:deterministic_dojo_conversation_grade, conversation, turn_summaries)

      assert_equal "PASS", grade["verdict"], grade["findings"].join(" ")
    end

    test "multilingual dojo guidance selects one five turn scenario per supported language" do
      previous_limit = ENV.delete("ASK_RECURSIVE_DOJO_CONVERSATION_LIMIT")
      scenarios = AskAutopilotTest.send(:dojo_conversation_scenarios, "multilingual language dojo")

      assert_equal %w[es zh vi ru ar tl ko pt], scenarios.map { |scenario| scenario[:language_code].to_s }
      assert_equal 8, scenarios.length

      scenarios.each do |scenario|
        assert scenario[:id].to_s.start_with?("multilingual_")
        assert_equal 5, scenario[:turns].length, scenario[:id].to_s
        assert scenario[:language_label].present?, scenario[:id].to_s
        assert scenario[:objective].to_s.match?(/Detect/i), scenario[:id].to_s
      end

      turns = scenarios.flat_map { |scenario| scenario[:turns].map(&:to_s) }
      assert_equal turns.length, turns.uniq.length
    ensure
      ENV["ASK_RECURSIVE_DOJO_CONVERSATION_LIMIT"] = previous_limit if previous_limit.present?
    end

    test "multilingual dojo openings hit the expected language detector" do
      AskAutopilotTest.send(:multilingual_dojo_conversation_scenarios).each do |scenario|
        detection = SmsLanguageSupport.detect_language(scenario[:turns].first)

        assert_equal scenario[:language_code], detection.fetch(:code), scenario[:id].to_s
      end
    end

    test "ask simulator payload preserves multilingual display fields" do
      message = AskAutopilotTest.send(
        :message_from_event,
        {
          "direction" => "inbound",
          "role" => "dojo_conversation_customer",
          "body" => "What is the cheapest option to start?",
          "original_body" => "¿Cuál es la opción más barata para empezar?",
          "language_code" => "es",
          "language_label" => "Spanish",
          "language_translated" => true,
          "translation_provider" => "deterministic/spanglish"
        }
      )

      assert_equal "What is the cheapest option to start?", message["body"]
      assert_equal "¿Cuál es la opción más barata para empezar?", message["original_body"]
      assert_equal "es", message["language_code"]
      assert_equal "Spanish", message["language_label"]
      assert_equal true, message["language_translated"]
      assert_equal "deterministic/spanglish", message["translation_provider"]
    end

    test "outbound translation failure uses product phrasebook instead of english or wait copy" do
      previous_translation_enabled = ENV["WIZWIKI_SMS_LANGUAGE_TRANSLATION_ENABLED"]
      ENV["WIZWIKI_SMS_LANGUAGE_TRANSLATION_ENABLED"] = "0"
      english = "The best price per sign comes with volume, but the cheapest total Yard Signs option is 10 signs for $99 double-sided. For the yard-sign deal, stakes, shipping, and design are included. Want to start there?"
      stage = OpenStruct.new(metadata: {
        "sms_language_preferred_code" => "es",
        "sms_language_preferred_label" => "Spanish"
      })

      result = SmsLanguageSupport.prepare_outbound_body(stage: stage, body: english)

      refute_equal english, result.body
      assert SmsLanguageSupport.target_language_signal?(result.body, "es")
      assert_match(/\$99/, result.body)
      refute_match(/The best price per sign|Dame un momento/i, result.body)
      assert_equal "es", result.language_code
      assert_equal true, result.translated
      assert_equal "deterministic/sms_phrasebook", result.event["translation_provider"]
      assert_nil result.event["language_translation_error"]
      refute result.event.key?("language_failsafe")
      assert_equal english, result.event["english_body"]
    ensure
      if previous_translation_enabled.nil?
        ENV.delete("WIZWIKI_SMS_LANGUAGE_TRANSLATION_ENABLED")
      else
        ENV["WIZWIKI_SMS_LANGUAGE_TRANSLATION_ENABLED"] = previous_translation_enabled
      end
    end

    test "product phrasebook keeps yard sign per-unit answer distinct from cheapest answer" do
      previous_translation_enabled = ENV["WIZWIKI_SMS_LANGUAGE_TRANSLATION_ENABLED"]
      ENV["WIZWIKI_SMS_LANGUAGE_TRANSLATION_ENABLED"] = "0"
      english = "The listed Yard Signs minimum is 10 signs for $99, which works out to $9.90 per sign. There is not a one-sign checkout; the order minimum starts at that 10-sign option."
      stage = OpenStruct.new(metadata: {
        "sms_language_preferred_code" => "es",
        "sms_language_preferred_label" => "Spanish"
      })

      result = SmsLanguageSupport.prepare_outbound_body(stage: stage, body: english)

      assert SmsLanguageSupport.target_language_signal?(result.body, "es")
      assert_match(/\$9\.90/, result.body)
      assert_match(/No hay checkout/i, result.body)
      assert_equal "deterministic/sms_phrasebook", result.event["translation_provider"]
    ensure
      if previous_translation_enabled.nil?
        ENV.delete("WIZWIKI_SMS_LANGUAGE_TRANSLATION_ENABLED")
      else
        ENV["WIZWIKI_SMS_LANGUAGE_TRANSLATION_ENABLED"] = previous_translation_enabled
      end
    end

    test "dojo grading uses translated customer bodies for multilingual turns" do
      messages = AskAutopilotTest.send(
        :dojo_grade_customer_messages,
        [
          {
            "body" => "What products besides signs can you offer?",
            "original_body" => "Какие продукты кроме табличек вы можете предложить?",
            "translated_to" => "English"
          }
        ],
        fallback_messages: ["Какие продукты кроме табличек вы можете предложить?"]
      )

      assert_equal ["What products besides signs can you offer?"], messages
      assert_equal "What products besides signs can you offer?", AskAutopilotTest.send(:dojo_grade_customer_text, messages, fallback: "fallback", delay_seconds: 25)
    end

    test "print custom recognizers keep vague followups in prior print context" do
      assert AskAutopilotTest.send(:simulator_print_products_question?, "I need printed materials for a cleaning company.")

      metadata = {
        "recursive_dojo_isolated_thread" => [
          { "body" => "I need printed materials for a cleaning company." },
          { "body" => "We can help with business cards, door hangers, flyers, and related print pieces." }
        ]
      }

      assert AskAutopilotTest.send(
        :simulator_messy_print_consultant_question?,
        "I do not know sizes or quantities. This is too custom.",
        metadata: metadata
      )
    end

    test "conversation grade passes normalized multilingual custom print handoff" do
      conversation = {
        title: "Russian messy print products and consultant",
        checks: %w[
          print_products_coverage
          no_bundle_overpush
          messy_print_consultant_handoff
        ]
      }
      turn_summaries = [
        {
          "turn" => 1,
          "customer" => "Please reply in Russian. I need printed materials for a cleaning company.",
          "answer" => "WIZWIKI can help with practical print pieces like business cards, door hangers, flyers, postcards, yard signs, rack cards, and related campaign materials. If it gets custom, a marketing consultant can help map it out."
        },
        {
          "turn" => 2,
          "customer" => "What products besides signs can you offer?",
          "answer" => "We can help with business cards, door hangers, flyers, rack cards, postcards, yard signs, and related print pieces."
        },
        {
          "turn" => 3,
          "customer" => "I need business cards, door hangers, and maybe flyers.",
          "answer" => "Yes. WIZWIKI can help with business cards, door hangers, and flyers. If you have rough quantities, I can point you to the right path; if it gets custom, a marketing consultant can map it out."
        },
        {
          "turn" => 4,
          "customer" => "I do not know sizes or quantities. This is too custom.",
          "answer" => "For flyers, business cards, and door hangers, sizes and quantities are exactly what a marketing consultant should help map out so we quote it cleanly. What is the best way for them to reach you?"
        },
        {
          "turn" => 5,
          "customer" => "Can a marketing consultant help choose?",
          "answer" => "Yes. A marketing consultant can help choose the custom print mix, including flyers, business cards, and door hangers, and map out sizes and quantities."
        }
      ]

      grade = AskAutopilotTest.send(:deterministic_dojo_conversation_grade, conversation, turn_summaries)

      assert_equal "PASS", grade["verdict"], grade["findings"].join(" ")
    end

    test "conversation grade passes normalized multilingual yard sign unit math" do
      conversation = {
        title: "Spanish yard-sign cheapest option and one-sign math",
        checks: %w[
          yard_sign_cheapest_99
          one_unit_yard_sign_math
          design_shipping_included
          yard_sign_checkout_link
        ]
      }
      turn_summaries = [
        {
          "turn" => 1,
          "customer" => "Please reply in Spanish. What is the cheapest option to start?",
          "answer" => "The cheapest yard-sign entry point is 10 signs for $99. Larger tiers have better per-sign pricing, but $99 is the smallest real checkout."
        },
        {
          "turn" => 2,
          "customer" => "Does that include design, stakes, and shipping?",
          "answer" => "Yes. The yard-sign package includes design help, stakes, and shipping."
        },
        {
          "turn" => 3,
          "customer" => "How much would each yard sign cost?",
          "answer" => "There is not a one-sign checkout. The smallest real checkout is 10 signs for $99, which works out to $9.90 per sign."
        },
        {
          "turn" => 4,
          "customer" => "Send the 10 sign checkout link.",
          "answer" => "Here is the 10-sign checkout link: https://shop.example.invalid/products/24x18-yard-signs"
        }
      ]

      grade = AskAutopilotTest.send(:deterministic_dojo_conversation_grade, conversation, turn_summaries)

      assert_equal "PASS", grade["verdict"], grade["findings"].join(" ")
    end

    test "conversation grade catches localized display fallback even with good english body" do
      conversation = {
        title: "Spanish yard-sign cheapest option and one-sign math",
        checks: %w[yard_sign_cheapest_99]
      }
      turn_summaries = [
        {
          "turn" => 1,
          "customer" => "What is the cheapest option to start?",
          "answer" => "Cheapest overall is the yard-sign entry point: 10 signs for $99. For the yard-sign deal, stakes, shipping, and design are included.",
          "answer_original" => "Estoy revisando eso para responderte bien en español. Dame un momento."
        }
      ]

      grade = AskAutopilotTest.send(:deterministic_dojo_conversation_grade, conversation, turn_summaries)

      assert_equal "REVIEW", grade["verdict"]
      assert grade["findings"].any? { |finding| finding.match?(%r{displayed a wait/fallback}i) }
    end

    test "conversation grade catches english display fallback in multilingual thread" do
      conversation = {
        title: "Spanish yard-sign cheapest option and one-sign math",
        checks: %w[yard_sign_cheapest_99]
      }
      turn_summaries = [
        {
          "turn" => 1,
          "customer" => "What is the cheapest option to start?",
          "language_code" => "es",
          "language_label" => "Spanish",
          "answer" => "Cheapest overall is the yard-sign entry point: 10 signs for $99. For the yard-sign deal, stakes, shipping, and design are included.",
          "answer_original" => "Cheapest overall is the yard-sign entry point: 10 signs for $99. For the yard-sign deal, stakes, shipping, and design are included."
        }
      ]

      grade = AskAutopilotTest.send(:deterministic_dojo_conversation_grade, conversation, turn_summaries)

      assert_equal "REVIEW", grade["verdict"]
      assert grade["findings"].any? { |finding| finding.match?(/preferred language/i) }
    end

    test "conversation grade passes normalized multilingual postcard full price sheet" do
      conversation = {
        title: "Chinese postcard special price sheet",
        checks: %w[
          postcard_special_all_tiers
          postcard_5000_special
          link_after_acceptance
        ]
      }
      turn_summaries = [
        {
          "turn" => 1,
          "customer" => "Please reply in Chinese. What is the 4th of July postcard special?",
          "answer" => "For the 4th of July postcard Block Sale, 1,000 postcards is $790."
        },
        {
          "turn" => 2,
          "customer" => "Please list the full price sheet.",
          "answer" => "The 4th of July postcard tiers are 1,000 for $790, 2,500 for $1,725, 5,000 for $3,250, 10,000 for $6,300, and 25,000 for $14,750."
        },
        {
          "turn" => 3,
          "customer" => "What is the total for 5,000 postcards?",
          "answer" => "The 5,000-postcard 4th of July total is $3,250."
        },
        {
          "turn" => 4,
          "customer" => "Please send the checkout link for 5,000 postcards.",
          "answer" => "Here is the 5,000-postcard checkout link: https://shop.example.invalid/products/postcard-block-sale-0704"
        }
      ]

      grade = AskAutopilotTest.send(:deterministic_dojo_conversation_grade, conversation, turn_summaries)

      assert_equal "PASS", grade["verdict"], grade["findings"].join(" ")
    end

    test "conversation grade picks explicit direct mail strategy turn after comparison" do
      conversation = {
        title: "Arabic direct-mail strategy boundary",
        checks: %w[
          eddm_nb_plain_compare
          direct_mail_strategy_handoff
        ]
      }
      turn_summaries = [
        {
          "turn" => 1,
          "customer" => "What is the difference between EDDM and Neighborhood Blitz?",
          "answer" => "EDDM is the mail-only route at $399 for one carrier route. Neighborhood Blitz is $699 and gives a broader local visibility push with postcards plus pieces like signs and door hangers."
        },
        {
          "turn" => 2,
          "customer" => "Can you choose the neighborhoods, lists, and targeting strategy completely?",
          "answer" => "A marketing consultant should help map out the targeting strategy, neighborhoods, routes, and list details so the plan is clean. Want me to get someone connected?"
        }
      ]

      grade = AskAutopilotTest.send(:deterministic_dojo_conversation_grade, conversation, turn_summaries)

      assert_equal "PASS", grade["verdict"], grade["findings"].join(" ")
    end

    test "conversation grade catches double text answers that miss active questions" do
      conversation = {
        title: "Double-text before Thumper replies",
        checks: %w[double_text_before_reply yard_sign_50_price design_shipping_included]
      }
      turn_summaries = [
        {
          "turn" => 1,
          "customer" => "We need yard signs. +25s: Also, how much are 50 signs and do they include stakes?",
          "customer_messages" => [
            "We need yard signs. What are my options?",
            "Also, how much are 50 signs and do they include stakes?"
          ],
          "customer_message_count" => 2,
          "customer_delay_seconds" => 25,
          "answer" => "50 signs are $249."
        }
      ]

      grade = AskAutopilotTest.send(:deterministic_dojo_conversation_grade, conversation, turn_summaries)

      assert_equal "REVIEW", grade["verdict"]
      assert grade["findings"].any? { |finding| finding.match?(/included|stakes|Double-text/i) }
    end

    test "conversation grade ignores superseded link request after postcard pivot" do
      conversation = {
        title: "Customer changing lanes mid-thread",
        checks: %w[decision_change_honors_latest postcard_4th_special link_after_acceptance]
      }
      turn_summaries = [
        {
          "turn" => 1,
          "customer" => "I was looking at 50 yard signs for my roofing company.",
          "answer" => "For 50 yard signs, you are at $249 with design help, stakes, and shipping included."
        },
        {
          "turn" => 2,
          "customer" => "Can you send the 50 sign checkout link? +25s: Actually nevermind, I prefer postcards instead. What is the special for 1,000 homes?",
          "customer_messages" => [
            "Can you send the 50 sign checkout link?",
            "Actually nevermind, I prefer postcards instead. What is the special for 1,000 homes?"
          ],
          "customer_message_count" => 2,
          "customer_delay_seconds" => 25,
          "answer" => "For mailing around 1,000 homes, the 4th of July postcard Block Sale is 1,000 postcards for $790. That is the closest postcard special tier; want me to send that checkout link?"
        },
        {
          "turn" => 3,
          "customer" => "Yes, send the 1,000 postcard special link.",
          "answer" => "Yes. For 1,000 postcards, the 4th of July postcard Block Sale is $790. Here is the checkout link: https://shop.example.invalid/products/postcard-block-sale-0704"
        }
      ]

      grade = AskAutopilotTest.send(:deterministic_dojo_conversation_grade, conversation, turn_summaries)

      assert_equal "PASS", grade["verdict"], grade["findings"].join(" ")
      refute grade["findings"].any? { |finding| finding.match?(/did not send one|Acceptance turn asked/i) }
    end

    test "conversation grade passes concise proof and rough logo answer" do
      conversation = {
        title: "Proof/design question answered directly",
        checks: %w[design_proof_flow proof_design_concise_not_canned no_repeated_lane_discovery]
      }
      turn_summaries = [
        {
          "turn" => 1,
          "customer" => "I have a rough logo screenshot for yard signs.",
          "answer" => "Yes, we can help with yard signs. For the yard-sign deal, stakes, shipping, and design are included."
        },
        {
          "turn" => 2,
          "customer" => "Can I approve a proof before printing, and can your team clean up the logo? Please keep it simple.",
          "answer" => "Yes. You approve a proof before anything prints, and the team can use or clean up a rough logo through the intake form after checkout."
        }
      ]

      grade = AskAutopilotTest.send(:deterministic_dojo_conversation_grade, conversation, turn_summaries)

      assert_equal "PASS", grade["verdict"], grade["findings"].join(" ")
    end

    test "conversation grade catches rush followup that falls back to yard sign tiers" do
      conversation = {
        title: "Triple-text before Thumper replies",
        checks: %w[triple_text_before_reply yard_sign_100_price design_proof_flow rush_consultant_no_checkout]
      }
      turn_summaries = [
        {
          "turn" => 1,
          "customer" => "I need signs for my landscaping company. +25s: What do 100 yard signs cost? +50s: Can I approve a proof before printing too?",
          "customer_messages" => [
            "I need signs for my landscaping company.",
            "What do 100 yard signs cost?",
            "Can I approve a proof before printing too?"
          ],
          "customer_message_count" => 3,
          "customer_delay_seconds" => 25,
          "answer" => "For 100 yard signs, you are at $399 with design help, stakes, and shipping included. Yes, you will get a proof to approve before printing; nothing prints until you approve it."
        },
        {
          "turn" => 2,
          "customer" => "Actually we may need them fast. Can rush go through normal checkout?",
          "answer" => "I can help with yard signs. Signs-only options are 10 for $99, 20 for $159, 50 for $249, and 100 for $399. Stakes, shipping, and design are included. Were you thinking closer to 20, 50, or 100?"
        }
      ]

      grade = AskAutopilotTest.send(:deterministic_dojo_conversation_grade, conversation, turn_summaries)

      assert_equal "REVIEW", grade["verdict"]
      assert grade["findings"].any? { |finding| finding.match?(/rush|timing/i) }
    end

    test "review all grade catches stale business card link after door hanger acceptance and human request" do
      conversation = {
        title: "Review all",
        checks: %w[
          review_all_door_hanger_acceptance
          review_all_human_handoff
        ]
      }
      turn_summaries = [
        {
          "turn" => 1,
          "customer" => "Yes please +10s: this is taking too long i want to talke ot a human too",
          "customer_messages" => [
            "Yes please",
            "this is taking too long i want to talke ot a human too"
          ],
          "customer_message_count" => 2,
          "customer_delay_seconds" => 10,
          "answer" => "Business Cards starts at 250 for $70. Here is the checkout link: https://shop.example.invalid/products/business-cards"
        }
      ]

      grade = AskAutopilotTest.send(:deterministic_dojo_conversation_grade, conversation, turn_summaries)

      assert_equal "REVIEW", grade["verdict"]
      assert grade["findings"].any? { |finding| finding.match?(/Door Hangers|Business Cards|human/i) }
    end

    test "review all grade rejects an unreviewed product link even with human handoff" do
      conversation = {
        title: "Review all",
        checks: %w[
          review_all_door_hanger_acceptance
          review_all_human_handoff
        ]
      }
      turn_summaries = [
        {
          "turn" => 1,
          "customer" => "Yes please +10s: this is taking too long i want to talke ot a human too",
          "customer_messages" => [
            "Yes please",
            "this is taking too long i want to talke ot a human too"
          ],
          "customer_message_count" => 2,
          "customer_delay_seconds" => 10,
          "answer" => "Here is the Door Hangers checkout link: https://shop.example.invalid/products/door-hangers. I can also have a marketing consultant follow up so a human can help from here."
        }
      ]

      grade = AskAutopilotTest.send(:deterministic_dojo_conversation_grade, conversation, turn_summaries)

      assert_equal "REVIEW", grade["verdict"]
      assert grade["findings"].any? { |finding| finding.match?(/Door Hangers|checkout|reviewed/i) }
    end
  end
end
