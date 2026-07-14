require "test_helper"

module DealReports
  class CommsDraftWriterTest < ActiveSupport::TestCase
    setup do
      @writer = CommsDraftWriter.allocate
      @writer.instance_variable_set(
        :@metadata,
        {
          "sms_thread" => [
            {
              "channel" => "sms",
              "direction" => "inbound",
              "body" => "750",
              "created_at" => 1.minute.ago.iso8601
            }
          ]
        }
      )
      @writer.instance_variable_set(:@operator_prompt, "")
    end

    test "sendable extraction preserves complete multiline SMS answers" do
      answer = <<~SMS
        You're targeting 750 homes with both postcards and yard signs.
        The Neighborhood Blitz bundle includes EDDM postcards, deluxe A-frames, and 500 rack cards -- all for $699.
        Would you like to proceed with that?
      SMS

      assert_equal answer.squish, @writer.send(:extract_sendable_sms_candidate, answer)
    end

    test "sendable extraction skips internal context and keeps the labeled SMS body" do
      raw = <<~TEXT
        latest_inbound_event: 750
        conversation_state: route_code=NEIGHBORHOOD_BLITZ
        SMS: You're targeting 750 homes with both postcards and yard signs. The Neighborhood Blitz bundle includes EDDM postcards, deluxe A-frames, and 500 rack cards -- all for $699. Would you like to proceed with that?
      TEXT

      assert_equal(
        "You're targeting 750 homes with both postcards and yard signs. The Neighborhood Blitz bundle includes EDDM postcards, deluxe A-frames, and 500 rack cards -- all for $699. Would you like to proceed with that?",
        @writer.send(:extract_sendable_sms_candidate, raw)
      )
    end

    test "guardrail retry treats underscore quality gate reasons as retryable" do
      assert @writer.send(:guardrail_retryable_rejection?, "rejected_sms_quality_gate")
      assert_equal 2, @writer.send(:guardrail_retry_limit)
    end

    test "fine training query puts the live customer message before generic retrieval language" do
      query = @writer.send(:fine_training_semantic_query)

      assert query.start_with?("Latest inbound: 750")
      assert_operator query.index("Latest inbound: 750"), :<, query.index("fine-training retrieval")
    end

    test "local model connection failures are treated as worker failures" do
      assert @writer.send(:local_worker_failure_reason?, "Errno::ECONNREFUSED: Failed to open TCP connection to 127.0.0.1:11434")
    end

    test "route validation drops every link when no reviewed catalog is configured" do
      links = @writer.send(
        :route_valid_shopify_links,
        {
          "EDDM" => "https://shop.example.invalid/products/every-door-direct-mail-sample_owner",
          "PRO_PACK" => "https://shop.example.invalid/products/pro-pack-bundle-deal-100-yard-signs-1000-business-cards-1000-door-hangers-sample_owner;",
          "STARTER_PACK" => "https://shop.example.invalid/products/starter-pack-bundle-deal-20-yard-signs-500-business-cards-500-door-hangers-sample_owner",
          "NEIGHBORHOOD_BLITZ" => "https://shop.example.invalid/products/neighborhood-blitz-sample_owner",
          "LAWN_SIGNS" => "https://shop.example.invalid/products/24x18-yard-signs-sample_owner"
        }
      )

      assert_empty links
    end

    test "route validation does not infer authority from plausible URL handles" do
      links = @writer.send(
        :route_valid_shopify_links,
        {
          "EDDM" => "https://shop.example.invalid/products/eddm-postcards",
          "STARTER_PACK" => "https://shop.example.invalid/products/starter-pack",
          "NEIGHBORHOOD_BLITZ" => "https://shop.example.invalid/products/main-course-bundle-eddm-postcards-1-deluxe-a-frames-500-rack-cards-sample_owner"
        }
      )

      assert_empty links
    end

    test "generic bundle question answers starter and pro bundles instead of postcard lane" do
      @writer.instance_variable_set(
        :@metadata,
        {
          "product_interest_code" => "EDDM",
          "comms_bot_state" => { "route_code" => "EDDM" },
          "sms_thread" => [
            {
              "channel" => "sms",
              "direction" => "inbound",
              "body" => "Actually just postcards",
              "created_at" => 4.minutes.ago.iso8601
            },
            {
              "channel" => "sms",
              "direction" => "outbound",
              "body" => "For 500 homes, EDDM is the postcard reach path.",
              "created_at" => 3.minutes.ago.iso8601
            },
            {
              "channel" => "sms",
              "direction" => "inbound",
              "body" => "Any bundles?",
              "created_at" => 1.minute.ago.iso8601
            }
          ]
        }
      )

      reply = @writer.send(:deterministic_known_sms_answer, "Any bundles?")

      assert_match(/Starter Pack/i, reply)
      assert_match(/Pro Pack/i, reply)
      assert_match(/business cards/i, reply)
      refute_match(/\bEDDM\b/i, reply)
      refute_match(%r{every-door-direct-mail-sample_owner}, reply)
    end

    test "plain product selection does not sound like a correction" do
      @writer.instance_variable_set(
        :@metadata,
        {
          "sms_thread" => [
            {
              "channel" => "sms",
              "direction" => "outbound",
              "body" => "Are you looking for postcards, yard signs, or both?",
              "created_at" => 2.minutes.ago.iso8601
            },
            {
              "channel" => "sms",
              "direction" => "inbound",
              "body" => "Signs",
              "created_at" => 1.minute.ago.iso8601
            }
          ]
        }
      )

      body = @writer.send(
        :safe_persisted_sms_body,
        "Got it, signs instead. For 18x24 yard signs, 10 are $99. What quantity feels closest?"
      )

      assert_equal "Got it, signs. For 18x24 yard signs, 10 are $99. What quantity feels closest?", body
    end

    test "explicit product pivot can still use instead language" do
      @writer.instance_variable_set(
        :@metadata,
        {
          "sms_thread" => [
            {
              "channel" => "sms",
              "direction" => "inbound",
              "body" => "Actually signs instead",
              "created_at" => 1.minute.ago.iso8601
            }
          ]
        }
      )

      body = @writer.send(
        :safe_persisted_sms_body,
        "Got it, signs instead. For 18x24 yard signs, 10 are $99. What quantity feels closest?"
      )

      assert_equal "Got it, signs instead. For 18x24 yard signs, 10 are $99. What quantity feels closest?", body
    end

    test "worker answer is stale when a newer inbound arrived after it was queued" do
      queued_at = 10.minutes.ago
      @writer.instance_variable_set(
        :@metadata,
        {
          "sms_thread" => [
            {
              "channel" => "sms",
              "direction" => "inbound",
              "body" => "Signs please",
              "status" => "received",
              "created_at" => 9.minutes.ago.iso8601
            },
            {
              "channel" => "sms",
              "direction" => "inbound",
              "body" => "Actually I only want postcards",
              "status" => "received",
              "created_at" => 1.minute.ago.iso8601
            }
          ]
        }
      )

      assert @writer.send(:inbound_received_after?, queued_at)
      assert @writer.send(:stale_worker_rejection_reason?, "ignored_after_newer_inbound")
    end

    test "worker answer is not stale when it was queued after the latest inbound" do
      queued_at = 30.seconds.ago
      @writer.instance_variable_set(
        :@metadata,
        {
          "sms_thread" => [
            {
              "channel" => "sms",
              "direction" => "inbound",
              "body" => "Actually I only want postcards",
              "status" => "received",
              "created_at" => 1.minute.ago.iso8601
            }
          ]
        }
      )

      refute @writer.send(:inbound_received_after?, queued_at)
    end

    test "bare home count reply prevents repeated home count question" do
      @writer.instance_variable_set(
        :@metadata,
        {
          "product_interest_code" => "EDDM",
          "comms_bot_state" => { "route_code" => "EDDM" },
          "sms_thread" => [
            {
              "channel" => "sms",
              "direction" => "outbound",
              "body" => "EDDM is the mail-only postcard path by route. For 500-700 homes, it's $399. What's the home count you're targeting?",
              "created_at" => 3.minutes.ago.iso8601
            },
            {
              "channel" => "sms",
              "direction" => "inbound",
              "body" => "1250",
              "created_at" => 2.minutes.ago.iso8601
            }
          ]
        }
      )

      assert_equal "1250 homes", @writer.send(:campaign_fit_payload)[:household_count]
      assert @writer.send(
        :asks_for_known_fit_field?,
        "For 1,250 homes, it's $790. What's the home count you're targeting?"
      )
      refute @writer.send(
        :acceptable_sms_body?,
        "For 1,250 homes, it's $790. What's the home count you're targeting?"
      )
    end

    test "bare home count avoids unsupported pricing when the catalog is empty" do
      @writer.instance_variable_set(
        :@metadata,
        {
          "captured_contact_name" => "Sample Contact",
          "company_name" => "Prices",
          "product_interest_code" => "EDDM",
          "comms_bot_state" => {
            "route_code" => "EDDM",
            "campaign_fit" => {
              "household_count" => "500 homes",
              "wants_postcards" => true,
              "missing_fit_signals" => ["artwork_status"]
            }
          },
          "sms_thread" => [
            {
              "channel" => "sms",
              "direction" => "outbound",
              "body" => "The standard EDDM route starts at $399. About how many homes are you trying to reach?",
              "created_at" => 3.minutes.ago.iso8601
            },
            {
              "channel" => "sms",
              "direction" => "inbound",
              "body" => "500",
              "created_at" => 2.minutes.ago.iso8601
            }
          ]
        }
      )
      @writer.instance_variable_set(
        :@operator_prompt,
        "Customer replied from +13135550100: 500. Draft the best next short SMS reply as Thumper from WIZWIKI CRM."
      )
      @writer.instance_variable_set(:@writer_model, "nvidia:nemotron")
      @writer.instance_variable_set(:@copilot, false)

      rewrite = @writer.send(
        :numeric_route_guardrail_reply,
        "Thanks. How many homes are you trying to reach?",
        "500"
      )
      draft = @writer.send(:fallback_draft, "asks_for_known_fit_field")

      assert_match(/artwork|logo|design|creative|operator|confirm/i, rewrite)
      refute_match(/\$\s*\d|https?:\/\//i, rewrite)
      refute @writer.send(
        :asks_for_known_fit_field?,
        "For 500 homes, the standard postcard path starts at $399; EDDM route mail usually reaches about 500-700 homes. Want the $399 postcard link?"
      )
      assert_equal "thumper_guardrail", draft["draft_source"]
      assert_equal "rewritten", draft["sms_quality_gate"]
      refute_match(/\$\s*\d|https?:\/\//i, draft["body"])
      assert_nil @writer.send(:sms_quality_rejection_reason, draft["body"], include_drafts: false)
    end

    test "rejects signs only answer when customer asked mailboxes or both" do
      @writer.instance_variable_set(
        :@metadata,
        {
          "sms_thread" => [
            {
              "channel" => "sms",
              "direction" => "outbound",
              "body" => "Are you trying to reach mailboxes, get signs in the ground, or do both?",
              "created_at" => 3.minutes.ago.iso8601
            },
            {
              "channel" => "sms",
              "direction" => "inbound",
              "body" => "Reach mailboxes",
              "created_at" => 2.minutes.ago.iso8601
            },
            {
              "channel" => "sms",
              "direction" => "inbound",
              "body" => "Or maybe both",
              "created_at" => 1.minute.ago.iso8601
            }
          ],
          "comms_bot_state" => {
            "route_code" => "NEIGHBORHOOD_BLITZ",
            "campaign_fit" => {
              "wants_postcards" => true,
              "wants_both" => true
            }
          }
        }
      )

      assert @writer.send(
        :signs_only_reply_against_mail_or_both_intent?,
        "For 18x24 yard signs, 10 are $99, 20 are $159, 50 are $249, and 100 are $399. Stakes, shipping, and design are included."
      )
      refute @writer.send(
        :signs_only_reply_against_mail_or_both_intent?,
        "Mailbox-only EDDM is $399 for one route. If you want mailboxes plus extra visibility, Neighborhood Blitz is $699."
      )
    end

    test "unconfigured pricing leaves every unanswered price question open" do
      @writer.instance_variable_set(
        :@metadata,
        {
          "sms_thread" => [
            {
              "channel" => "sms",
              "direction" => "outbound",
              "body" => "Would one route fit better?",
              "status" => "delivered",
              "created_at" => 3.minutes.ago.iso8601
            },
            {
              "channel" => "sms",
              "direction" => "inbound",
              "body" => "How much for 500 signs?",
              "status" => "received",
              "created_at" => 2.minutes.ago.iso8601
            },
            {
              "channel" => "sms",
              "direction" => "inbound",
              "body" => "How much for 500 postcards?",
              "status" => "received",
              "created_at" => 1.minute.ago.iso8601
            }
          ],
          "comms_bot_state" => {
            "route_code" => "NEIGHBORHOOD_BLITZ",
            "campaign_fit" => {
              "wants_signs" => true,
              "wants_postcards" => true,
              "wants_both" => true,
              "quantity_count" => "500 signs",
              "household_count" => "500 homes"
            }
          }
        }
      )

      assert_equal(
        ["How much for 500 signs?", "How much for 500 postcards?"],
        @writer.send(:open_customer_messages_payload).map { |event| event[:body] || event["body"] }
      )
      assert @writer.send(
        :misses_open_customer_messages?,
        "For 500 postcards, the standard EDDM route is $399 and usually covers about 500-700 homes."
      )
      assert @writer.send(
        :misses_open_customer_messages?,
        "For 500 yard signs, you’re at $1,699 with stakes, shipping, and design included. For 500 postcards, standard EDDM is $399 and usually covers about 500-700 homes."
      )
    end

    test "later decision change can supersede older open lane request" do
      @writer.instance_variable_set(
        :@metadata,
        {
          "sms_thread" => [
            {
              "channel" => "sms",
              "direction" => "outbound",
              "body" => "I can send the right link once you pick the lane.",
              "status" => "delivered",
              "created_at" => 3.minutes.ago.iso8601
            },
            {
              "channel" => "sms",
              "direction" => "inbound",
              "body" => "Send the 50 yard sign checkout link.",
              "status" => "received",
              "created_at" => 2.minutes.ago.iso8601
            },
            {
              "channel" => "sms",
              "direction" => "inbound",
              "body" => "Actually nevermind, I prefer postcards for 1,000 homes. What is the special?",
              "status" => "received",
              "created_at" => 1.minute.ago.iso8601
            }
          ]
        }
      )

      assert_equal(
        ["Actually nevermind, I prefer postcards for 1,000 homes. What is the special?"],
        @writer.send(:open_customer_messages_payload).map { |event| event[:body] || event["body"] }
      )
      refute @writer.send(
        :misses_open_customer_messages?,
        "We can switch to postcards. For 1,000 postcards, the 4th of July postcard Block Sale is $790."
      )
    end

    test "postcard price-only question can be answered without checkout link" do
      @writer.instance_variable_set(
        :@metadata,
        {
          "sms_thread" => [
            {
              "channel" => "sms",
              "direction" => "inbound",
              "body" => "How much for 500 postcards?",
              "created_at" => 1.minute.ago.iso8601
            }
          ]
        }
      )

      assert @writer.send(:price_only_pricing_question?, "How much for 500 postcards?")
      assert @writer.send(
        :price_only_pricing_answer_without_checkout_url?,
        "For 500 postcards, the standard EDDM route is $399 and usually covers about 500-700 homes.",
        "How much for 500 postcards?"
      )
      refute @writer.send(
        :price_only_pricing_answer_without_checkout_url?,
        "For 500 postcards, the standard EDDM route is $399. https://shop.example.invalid/products/postcard-block-sale-0704",
        "How much for 500 postcards?"
      )
    end

    test "explicit get link request still rejects an unreviewed checkout" do
      link = "https://shop.example.invalid/products/main-course-bundle-eddm-postcards-1-deluxe-a-frames-500-rack-cards-sample_owner"
      @writer.instance_variable_set(
        :@metadata,
        {
          "product_interest_code" => "NEIGHBORHOOD_BLITZ",
          "product_interest_label" => "Neighborhood Blitz",
          "shopify_link" => "https://shop.example.invalid/products/eddm-postcards",
          "sms_lane_monitor" => { "route_code" => "NEIGHBORHOOD_BLITZ", "latest_body" => "Let me get the link to the smallest blitz" },
          "sms_thread" => [
            {
              "channel" => "sms",
              "direction" => "inbound",
              "body" => "Let me get the link to the smallest blitz",
              "created_at" => 1.minute.ago.iso8601
            }
          ]
        }
      )
      @writer.define_singleton_method(:route_specific_shopify_link) { |route| route.to_s == "NEIGHBORHOOD_BLITZ" ? link : nil }

      body = "The smallest Neighborhood Blitz is $699 for 500 homes with postcards, 1 Deluxe A-Frame, and 500 Rack Cards. #{link}"

      assert @writer.send(:direct_checkout_link_request?, "Let me get the link to the smallest blitz")
      refute @writer.send(:route_link_answer_has_required_fit?, body)
    end

    test "bare checkout acceptance follows latest outbound product prompt over stale product lane" do
      @writer.instance_variable_set(
        :@metadata,
        {
          "product_interest_code" => "BUSINESS_CARDS",
          "product_interest_label" => "Business Cards",
          "shopify_link" => "https://shop.example.invalid/products/business-cards",
          "comms_bot_state" => {
            "route_code" => "BUSINESS_CARDS",
            "route_label" => "Business Cards",
            "shopify_link" => "https://shop.example.invalid/products/business-cards"
          },
          "sms_thread" => [
            {
              "channel" => "sms",
              "direction" => "inbound",
              "body" => "Can i get the business card link",
              "status" => "received",
              "created_at" => 5.minutes.ago.iso8601
            },
            {
              "channel" => "sms",
              "direction" => "outbound",
              "body" => "Yes. Business cards have a standalone option. Here is the Business Cards checkout link: https://shop.example.invalid/products/business-cards",
              "status" => "delivered",
              "created_at" => 4.minutes.ago.iso8601
            },
            {
              "channel" => "sms",
              "direction" => "inbound",
              "body" => "What about door hangers?",
              "status" => "received",
              "created_at" => 3.minutes.ago.iso8601
            },
            {
              "channel" => "sms",
              "direction" => "outbound",
              "body" => "Yes. Door hangers have a standalone 4.25x11 option. Want me to send the door-hanger checkout link?",
              "status" => "delivered",
              "created_at" => 2.minutes.ago.iso8601
            },
            {
              "channel" => "sms",
              "direction" => "inbound",
              "body" => "Yes please",
              "status" => "received",
              "created_at" => 1.minute.ago.iso8601
            }
          ]
        }
      )
      @writer.define_singleton_method(:route_specific_shopify_link) do |route|
        {
          "BUSINESS_CARDS" => "https://shop.example.invalid/products/business-cards",
          "DOOR_HANGERS" => "https://shop.example.invalid/products/door-hangers"
        }[route.to_s]
      end

      reply = @writer.send(:direct_checkout_link_reply, "Yes please")

      assert_equal "DOOR_HANGERS", @writer.send(:checkout_request_route, "Yes please")
      assert_includes reply, "https://shop.example.invalid/products/door-hangers"
      refute_includes reply, "business-cards"
      refute @writer.send(:direct_checkout_link_reply_sendable?, reply)
    end

    test "yard sign included-items checkout request still sends the link" do
      link = "https://shop.example.invalid/products/24x18-yard-signs-sample_owner"
      @writer.instance_variable_set(
        :@metadata,
        {
          "comms_bot_state" => { "route_code" => "LAWN_SIGNS" },
          "sms_thread" => [
            {
              "channel" => "sms",
              "direction" => "inbound",
              "body" => "If that includes design and shipping too, send the 50 sign checkout.",
              "created_at" => 1.minute.ago.iso8601
            }
          ]
        }
      )
      @writer.define_singleton_method(:route_specific_shopify_link) { |route| route.to_s == "LAWN_SIGNS" ? link : nil }
      @writer.define_singleton_method(:shopify_product_sold_out?) { |_route| false }
      @writer.define_singleton_method(:product_details_for_route) do |_route|
        {
          price_table: { 50 => { "double_sided_included" => "$249" } },
          included: ["stakes", "shipping", "design"]
        }
      end

      reply = @writer.send(:fallback_reply_to_inbound, "If that includes design and shipping too, send the 50 sign checkout.")

      assert_includes reply, "$249"
      assert_includes reply, link
    end

    test "yard sign price plus included-items answer includes the quantity price first" do
      @writer.instance_variable_set(
        :@metadata,
        {
          "comms_bot_state" => { "route_code" => "LAWN_SIGNS" },
          "sms_thread" => [
            {
              "channel" => "sms",
              "direction" => "inbound",
              "body" => "How much are 500 yard signs, and does that include design, stakes, and shipping?",
              "created_at" => 1.minute.ago.iso8601
            }
          ]
        }
      )
      @writer.define_singleton_method(:product_details_for_route) do |_route|
        {
          price_table: { 500 => { "double_sided_included" => "$1,699" } },
          included: ["stakes", "shipping", "design"]
        }
      end

      reply = @writer.send(:yard_sign_included_items_reply, "How much are 500 yard signs, and does that include design, stakes, and shipping?")

      assert_match(/\AFor 500 yard signs, you are at \$1,699\b/, reply)
      assert_match(/design help, stakes, and shipping included/i, reply)
    end

    test "yard sign quantity acknowledgement with price and checkout question is sendable" do
      @writer.instance_variable_set(
        :@metadata,
        {
          "sms_lane_monitor" => { "route_code" => "LAWN_SIGNS" },
          "sms_thread" => [
            {
              "channel" => "sms",
              "direction" => "inbound",
              "body" => "I was looking at 50 yard signs for my roofing company.",
              "created_at" => 1.minute.ago.iso8601
            }
          ]
        }
      )
      @writer.define_singleton_method(:product_details_for_route) do |_route|
        {
          price_table: { 50 => { "double_sided_included" => "$249" } },
          included: ["stakes", "shipping", "design"]
        }
      end

      reply = "50 yard signs are $249 with stakes, shipping, and design included. Want the checkout link for that option?"

      assert @writer.send(:yard_sign_quantity_acknowledgement_sendable?, reply)
      assert @writer.send(:acceptable_sms_body?, reply)
      refute @writer.send(
        :acceptable_sms_body?,
        "50 yard signs are $249 with stakes, shipping, and design included. https://shop.example.invalid/products/24x18-yard-signs-sample_owner"
      )
    end

    test "print product questions cover business cards door hangers and flyers without yard sign drift" do
      assert @writer.send(:print_products_question?, "I need door hangers and business cards for a cleaning company.")
      assert @writer.send(:print_products_question?, "Maybe flyers too. What can you help with?")

      reply = @writer.send(:print_products_reply, "Could those include business cards, door hangers, or flyers?")

      assert_match(/Business cards, door hangers, and flyers/i, reply)
      refute_match(/Yard Signs start/i, reply)
    end

    test "rush checkout question requires rush answer instead of yard sign pricing" do
      @writer.instance_variable_set(
        :@metadata,
        {
          "comms_bot_state" => { "route_code" => "LAWN_SIGNS" },
          "sms_thread" => [
            {
              "channel" => "sms",
              "direction" => "inbound",
              "body" => "Can we rush them by next Friday, and should I use the normal checkout?",
              "created_at" => 1.minute.ago.iso8601
            }
          ]
        }
      )
      @writer.define_singleton_method(:turnaround_details) do
        {
          yard_signs_production: "7 to 10 business days after proof approval",
          shipping: "2 to 5 business days by UPS/FedEx ground",
          rush_print_window: "2 to 3 business days after proof approval"
        }
      end

      bad_reply = "I can help with yard signs. Signs-only options are 10 for $99, 20 for $159, 50 for $249, and 100 for $399."
      refute @writer.send(:acceptable_sms_body?, bad_reply)

      reply = @writer.send(:fallback_reply_to_inbound, "Can we rush them by next Friday, and should I use the normal checkout?")
      assert_match(/normal checkout/i, reply)
      assert_match(/marketing consultant/i, reply)
      assert_match(/proof approval/i, reply)
      refute_match(/\AFor \d+ yard signs/i, reply)
    end

    test "messy print follow up stays in print products and offers consultant" do
      @writer.instance_variable_set(
        :@metadata,
        {
          "sms_thread" => [
            {
              "channel" => "sms",
              "direction" => "inbound",
              "body" => "I need flyers, maybe business cards, maybe door hangers, but I do not know sizes or quantities.",
              "created_at" => 2.minutes.ago.iso8601
            },
            {
              "channel" => "sms",
              "direction" => "inbound",
              "body" => "Can Thumper figure all that out or should a real person help me choose?",
              "created_at" => 1.minute.ago.iso8601
            }
          ]
        }
      )

      assert @writer.send(:messy_print_consultant_question?, "Can Thumper figure all that out or should a real person help me choose?")
      refute @writer.send(:acceptable_sms_body?, "For 20 yard signs, you are at $159 with design help, stakes, and shipping included.")

      reply = @writer.send(:fallback_reply_to_inbound, "Can Thumper figure all that out or should a real person help me choose?")
      assert_match(/flyers/i, reply)
      assert_match(/business cards/i, reply)
      assert_match(/door hangers/i, reply)
      assert_match(/marketing consultant/i, reply)
      refute_match(/20 yard signs/i, reply)
    end

    test "deterministic fast path answers multilingual dojo product intents before model drafting" do
      @writer.instance_variable_set(
        :@metadata,
        {
          "comms_bot_state" => { "route_code" => "LAWN_SIGNS" },
          "sms_thread" => [
            {
              "channel" => "sms",
              "direction" => "inbound",
              "body" => "I want yard signs please.",
              "created_at" => 5.minutes.ago.iso8601
            }
          ]
        }
      )
      @writer.define_singleton_method(:product_details_for_route) do |_route|
        {
          price_table: {
            "10" => { "double_sided_included" => "$99" },
            "100" => { "double_sided_included" => "$399" },
            "500" => { "double_sided_included" => "$1,699" }
          },
          included: ["stakes", "shipping", "design"]
        }
      end
      @writer.define_singleton_method(:turnaround_details) do
        {
          yard_signs_production: "7 to 10 business days after proof approval",
          shipping: "2 to 5 business days by UPS/FedEx ground",
          rush_print_window: "2 to 3 business days after proof approval"
        }
      end

      assert_match(/10 for \$99/i, @writer.send(:deterministic_known_sms_answer, "I want yard signs please."))
      cheapest = @writer.send(:deterministic_known_sms_answer, "What is the cheapest option to start?")
      assert_match(/10 signs for \$99/i, cheapest)
      assert_match(/stakes, shipping, and design/i, cheapest)
      assert_match(/minimum is 10 signs for \$99/i, @writer.send(:deterministic_known_sms_answer, "How much would each yard sign cost?"))
      assert_match(/design help, stakes, and shipping/i, @writer.send(:deterministic_known_sms_answer, "Does it include design, stakes, and shipping?"))
      assert_match(/do not use the normal checkout/i, @writer.send(:deterministic_known_sms_answer, "Should I use the normal checkout for this rush order?"))
      assert_match(/business cards, door hangers, and flyers/i, @writer.send(:deterministic_known_sms_answer, "I need business cards, door hangers, and maybe flyers."))
    end

    test "deterministic fast path answers language preference in English for outbound translator" do
      @writer.instance_variable_set(
        :@metadata,
        {
          "sms_language_preferred_code" => "es",
          "sms_language_preferred_label" => "Spanish",
          "sms_thread" => [
            {
              "channel" => "sms",
              "direction" => "inbound",
              "body" => "If I prefer Spanish",
              "original_body" => "Si yo prefiero espanol",
              "created_at" => 1.minute.ago.iso8601
            }
          ]
        }
      )

      reply = @writer.send(:deterministic_known_sms_answer, "If I prefer Spanish")

      assert_equal "Yes, I can text you in Spanish. Are you thinking postcards, yard signs, or both?", reply
      refute_match(/[¿¡]/, reply)
      refute_match(/prefieres comunicarte/i, reply)
    end

    test "deterministic fast path answers supported language preferences in English" do
      {
        "es" => "Spanish",
        "zh" => "Chinese",
        "vi" => "Vietnamese",
        "ru" => "Russian",
        "ar" => "Arabic",
        "tl" => "Tagalog",
        "ko" => "Korean",
        "pt" => "Portuguese"
      }.each do |code, label|
        @writer.instance_variable_set(
          :@metadata,
          {
            "sms_language_preferred_code" => code,
            "sms_language_preferred_label" => label,
            "sms_thread" => [
              {
                "channel" => "sms",
                "direction" => "inbound",
                "body" => "I prefer #{label}.",
                "created_at" => 1.minute.ago.iso8601
              }
            ]
          }
        )

        assert_equal(
          "Yes, I can text you in #{label}. Are you thinking postcards, yard signs, or both?",
          @writer.send(:deterministic_known_sms_answer, "I prefer #{label}.")
        )
      end
    end

    test "deterministic fast path does not invent an unconfigured special" do
      @writer.instance_variable_set(
        :@metadata,
        {
          "comms_bot_state" => { "route_code" => "EDDM" },
          "sms_thread" => [
            {
              "channel" => "sms",
              "direction" => "inbound",
              "body" => "Please reply in Chinese. I want postcard marketing for a roofing company.",
              "created_at" => 5.minutes.ago.iso8601
            },
            {
              "channel" => "sms",
              "direction" => "inbound",
              "body" => "Are there any 4th of July postcard specials?",
              "created_at" => 4.minutes.ago.iso8601
            }
          ]
        }
      )
      previous_specials_flag = ENV["WIZWIKI_COMMS_CURRENT_SPECIALS_ENABLED"]
      ENV["WIZWIKI_COMMS_CURRENT_SPECIALS_ENABLED"] = "true"
      begin
        special = @writer.send(:deterministic_known_sms_answer, "Are there any 4th of July postcard specials?")
        assert_match(/do not have a reviewed active special/i, special)
        assert_match(/operator.*confirm/i, special)
        refute_match(/\$\s*\d|https?:\/\//i, special)
      ensure
        if previous_specials_flag.nil?
          ENV.delete("WIZWIKI_COMMS_CURRENT_SPECIALS_ENABLED")
        else
          ENV["WIZWIKI_COMMS_CURRENT_SPECIALS_ENABLED"] = previous_specials_flag
        end
      end
    end

    test "inactive specials fallback honors Sample Contact postcard pivot instead of reasking lane" do
      @writer.instance_variable_set(
        :@metadata,
        {
          "product_interest_code" => "EDDM",
          "comms_bot_state" => { "route_code" => "EDDM" },
          "sms_lane_monitor" => {
            "route_code" => "EDDM",
            "source" => "fresh_thread_scan",
            "evidence" => ["Actually I want postcards"],
            "latest_body" => "Do you have any specials?"
          },
          "sms_thread" => [
            {
              "channel" => "sms",
              "direction" => "inbound",
              "body" => "Let me get signs",
              "created_at" => 3.minutes.ago.iso8601
            },
            {
              "channel" => "sms",
              "direction" => "inbound",
              "body" => "Actually I want postcards",
              "created_at" => 2.minutes.ago.iso8601
            },
            {
              "channel" => "sms",
              "direction" => "inbound",
              "body" => "Do you have any specials?",
              "created_at" => 1.minute.ago.iso8601
            }
          ]
        }
      )
      previous_specials_flag = ENV["WIZWIKI_COMMS_CURRENT_SPECIALS_ENABLED"]
      ENV.delete("WIZWIKI_COMMS_CURRENT_SPECIALS_ENABLED")
      begin
        reply = @writer.send(:deterministic_known_sms_answer, "Do you have any specials?")

        assert_match(/do not have a reviewed active special/i, reply)
        assert_match(/operator.*confirm/i, reply)
        refute_match(/\$\s*\d|https?:\/\//i, reply)
      ensure
        if previous_specials_flag.nil?
          ENV.delete("WIZWIKI_COMMS_CURRENT_SPECIALS_ENABLED")
        else
          ENV["WIZWIKI_COMMS_CURRENT_SPECIALS_ENABLED"] = previous_specials_flag
        end
      end
    end

    test "yard sign specials recovery does not invent product or offer facts" do
      @writer.instance_variable_set(
        :@metadata,
        {
          "product_interest_code" => "LAWN_SIGNS",
          "comms_bot_state" => {
            "route_code" => "LAWN_SIGNS",
            "campaign_fit" => {
              "quantity_count" => "500 signs"
            }
          },
          "sms_thread" => [
            {
              "channel" => "sms",
              "direction" => "inbound",
              "body" => "I need 500 signs",
              "created_at" => 3.minutes.ago.iso8601
            },
            {
              "channel" => "sms",
              "direction" => "outbound",
              "body" => "For 500 signs, the price is $1,699. Here is the checkout link.",
              "created_at" => 2.minutes.ago.iso8601
            },
            {
              "channel" => "sms",
              "direction" => "inbound",
              "body" => "Do you have any specials?",
              "created_at" => 1.minute.ago.iso8601
            }
          ]
        }
      )
      @writer.define_singleton_method(:product_details_for_route) do |_route|
        {
          price_table: {
            "500" => { "double_sided_included" => "$1,699" }
          },
          included: ["stakes", "shipping", "design"]
        }
      end

      previous_specials_flag = ENV["WIZWIKI_COMMS_CURRENT_SPECIALS_ENABLED"]
      ENV["WIZWIKI_COMMS_CURRENT_SPECIALS_ENABLED"] = "true"
      begin
        reply = @writer.send(:current_specials_reply, "Do you have any specials?")

        assert_match(/do not have a reviewed active special/i, reply)
        assert_match(/operator.*confirm/i, reply)
        refute_match(/\$\s*\d|https?:\/\//i, reply)

        ENV["WIZWIKI_COMMS_CURRENT_SPECIALS_ENABLED"] = "false"
        inactive_reply = @writer.send(:current_specials_reply, "Do you have any specials?")
        assert_match(/do not have a reviewed active special/i, inactive_reply)
        refute_match(/\$\s*\d|https?:\/\//i, inactive_reply)
      ensure
        if previous_specials_flag.nil?
          ENV.delete("WIZWIKI_COMMS_CURRENT_SPECIALS_ENABLED")
        else
          ENV["WIZWIKI_COMMS_CURRENT_SPECIALS_ENABLED"] = previous_specials_flag
        end
      end
    end

    test "simple proof and logo question gets concise direct answer" do
      @writer.instance_variable_set(
        :@metadata,
        {
          "comms_bot_state" => { "route_code" => "LAWN_SIGNS" },
          "sms_thread" => [
            {
              "channel" => "sms",
              "direction" => "inbound",
              "body" => "Can I approve a proof before printing, and can your team clean up the logo? Please keep it simple.",
              "created_at" => 1.minute.ago.iso8601
            }
          ]
        }
      )

      reply = @writer.send(:design_process_reply, "LAWN_SIGNS")

      assert_match(/\AYes\. You approve a proof before anything prints/i, reply)
      assert_match(/clean up a rough logo/i, reply)
      assert_operator reply.length, :<, 180
    end

    test "artwork help stays in yard signs after recent bundle context" do
      @writer.instance_variable_set(
        :@metadata,
        {
          "product_interest_code" => "LAWN_SIGNS",
          "comms_bot_state" => { "route_code" => "LAWN_SIGNS" },
          "sms_thread" => [
            {
              "channel" => "sms",
              "direction" => "outbound",
              "body" => "Starter Pack is $299 with 20 signs, 500 business cards, and 500 door hangers.",
              "created_at" => 3.minutes.ago.iso8601
            },
            {
              "channel" => "sms",
              "direction" => "inbound",
              "body" => "On second thought I do want signs",
              "created_at" => 2.minutes.ago.iso8601
            },
            {
              "channel" => "sms",
              "direction" => "inbound",
              "body" => "So do I need artwork?",
              "created_at" => 1.minute.ago.iso8601
            }
          ]
        }
      )
      old_bad_reply = "The Starter Pack includes design support. Complete the order first, then the design team sends the intake form so you can upload images, logo, and notes. WIZWIKI can use the AI postcard/art builder or in-house designers, you review the proof, and nothing prints until approval."

      reply = @writer.send(:artwork_creation_help_reply)

      assert_equal "LAWN_SIGNS", @writer.send(:artwork_creation_route_for_inbound, "So do I need artwork?")
      assert_match(/You don'?t need a finished design/i, reply)
      refute_match(/Starter Pack/i, reply)
      assert_nil @writer.send(:sms_quality_rejection_reason, reply, include_drafts: false)
      assert_equal "missing_requested_product_context", @writer.send(:sms_quality_rejection_reason, old_bad_reply, include_drafts: false)
    end

    test "yard sign art cost question answers directly without price ladder" do
      @writer.instance_variable_set(
        :@metadata,
        {
          "product_interest_code" => "LAWN_SIGNS",
          "comms_bot_state" => { "route_code" => "LAWN_SIGNS" },
          "sms_thread" => [
            {
              "channel" => "sms",
              "direction" => "inbound",
              "body" => "How much is each sign?",
              "created_at" => 3.minutes.ago.iso8601
            },
            {
              "channel" => "sms",
              "direction" => "outbound",
              "body" => "10 yard signs are $99, so the smallest listed run works out to $9.90 per sign.",
              "created_at" => 2.minutes.ago.iso8601
            },
            {
              "channel" => "sms",
              "direction" => "inbound",
              "body" => "Do you charge extra for art?",
              "created_at" => 1.minute.ago.iso8601
            }
          ]
        }
      )

      reply = @writer.send(:deterministic_known_sms_answer, "Do you charge extra for art?")

      assert_match(/No extra charge for standard yard-sign design help/i, reply)
      assert_match(/Different front\/back designs add \$125/i, reply)
      assert_match(/approve a proof before print/i, reply)
      refute_match(/10 for \$99, 20 for \$159/i, reply)
      assert_nil @writer.send(:sms_quality_rejection_reason, reply, include_drafts: false)
    end

    test "stacked both specials and business cards answer combines open questions" do
      @writer.instance_variable_set(
        :@metadata,
        {
          "sms_thread" => [
            {
              "channel" => "sms",
              "direction" => "outbound",
              "body" => "Are you trying to reach mailboxes, get signs in the ground, or do both?",
              "created_at" => 4.minutes.ago.iso8601
            },
            {
              "channel" => "sms",
              "direction" => "inbound",
              "body" => "Both",
              "created_at" => 3.minutes.ago.iso8601
            },
            {
              "channel" => "sms",
              "direction" => "inbound",
              "body" => "Do you have any specials",
              "created_at" => 2.minutes.ago.iso8601
            },
            {
              "channel" => "sms",
              "direction" => "inbound",
              "body" => "Im looking for biz cards too",
              "created_at" => 1.minute.ago.iso8601
            }
          ]
        }
      )

      reply = @writer.send(:stacked_open_messages_reply)
      business_only = "Business cards have a standalone 16pt premium matte option. Standard quantities are 250 for $70, 500 for $75, and 1,000 for $80. Want me to send the Business Cards checkout link?"

      assert_match(/postcards\/signs/i, reply)
      assert_match(/Yard signs start at 10 for \$99/i, reply)
      assert_match(/EDDM postcards start at \$399/i, reply)
      assert_match(/special/i, reply)
      assert_match(/Business cards start at 250 for \$70/i, reply)
      refute @writer.send(:misses_open_customer_messages?, reply)
      assert @writer.send(:misses_open_customer_messages?, business_only)
    end

    test "signs only pivot fails closed when no reviewed catalog is configured" do
      @writer.instance_variable_set(
        :@metadata,
        {
          "product_interest_code" => "LAWN_SIGNS",
          "comms_bot_state" => {
            "route_code" => "LAWN_SIGNS",
            "campaign_fit" => { "wants_signs" => true }
          },
          "sms_thread" => [
            {
              "channel" => "sms",
              "direction" => "outbound",
              "body" => "Do you need postcards, yard signs, or both?",
              "created_at" => 5.minutes.ago.iso8601
            },
            {
              "channel" => "sms",
              "direction" => "inbound",
              "body" => "Postcards",
              "created_at" => 4.minutes.ago.iso8601
            },
            {
              "channel" => "sms",
              "direction" => "inbound",
              "body" => "Signs only please",
              "created_at" => 3.minutes.ago.iso8601
            },
            {
              "channel" => "sms",
              "direction" => "inbound",
              "body" => "Do you have specials",
              "created_at" => 2.minutes.ago.iso8601
            },
            {
              "channel" => "sms",
              "direction" => "inbound",
              "body" => "Do you have specials",
              "created_at" => 1.minute.ago.iso8601
            }
          ]
        }
      )

      assert_equal(
        ["Signs only please", "Do you have specials"],
        @writer.send(:open_customer_messages_payload).map { |event| event[:body] || event["body"] }
      )

      reply = @writer.send(:stacked_open_messages_reply)

      assert_match(/do not have a reviewed active special/i, reply)
      assert_match(/operator confirm current options/i, reply)
      refute_match(/\$\d|https?:\/\//i, reply)
      refute_match(/postcard-only|4th of July/i, reply)
      refute_match(/Are you looking at postcards/i, reply)
      refute @writer.send(:misses_open_customer_messages?, reply)
    end

    test "bare yes after mailing homes question does not accept older checkout prompt" do
      @writer.instance_variable_set(
        :@metadata,
        {
          "product_interest_code" => "BUSINESS_CARDS",
          "sms_thread" => [
            {
              "channel" => "sms",
              "direction" => "outbound",
              "status" => "delivered",
              "body" => "Business Cards have a standalone checkout. Want me to send the Business Cards checkout link?",
              "created_at" => 5.minutes.ago.iso8601
            },
            {
              "channel" => "sms",
              "direction" => "inbound",
              "status" => "received",
              "body" => "I also need signs and postcards",
              "created_at" => 4.minutes.ago.iso8601
            },
            {
              "channel" => "sms",
              "direction" => "outbound",
              "status" => "delivered",
              "body" => "We can do both. Yard signs start at 10 for $99. Mailed postcards start with one EDDM route at $399, or 1,000 on the 4th of July Block Sale for $790. Are you mailing homes too?",
              "created_at" => 3.minutes.ago.iso8601
            },
            {
              "channel" => "sms",
              "direction" => "inbound",
              "status" => "received",
              "body" => "Yes",
              "created_at" => 2.minutes.ago.iso8601
            }
          ]
        }
      )

      assert_nil @writer.send(:latest_outbound_checkout_prompt_route)
      assert_nil @writer.send(:accepted_recent_recommendation_route)
    end

    test "explicit starter pack artwork question explains the starter pack" do
      @writer.instance_variable_set(
        :@metadata,
        {
          "product_interest_code" => "LAWN_SIGNS",
          "comms_bot_state" => { "route_code" => "LAWN_SIGNS" },
          "sms_thread" => [
            {
              "channel" => "sms",
              "direction" => "inbound",
              "body" => "What is the Starter Pack, and do I need artwork?",
              "created_at" => 1.minute.ago.iso8601
            }
          ]
        }
      )

      reply = @writer.send(:artwork_creation_help_reply)

      assert_equal "STARTER_PACK", @writer.send(:artwork_creation_route_for_inbound, "What is the Starter Pack, and do I need artwork?")
      assert_match(/\$299/i, reply)
      assert_match(/20 yard signs/i, reply)
      assert_match(/500 business cards/i, reply)
      assert_match(/500 door hangers/i, reply)
      assert_nil @writer.send(:sms_quality_rejection_reason, reply, include_drafts: false)
    end
  end
end
