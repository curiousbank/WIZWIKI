require "json"
require "net/http"
require "uri"

module Comms
  class SlackNotifier
    class Error < StandardError; end
    ROUND_ROBIN_TITLE = "LEAD GEN 🐦 R:egg:UND R:egg:BIN".freeze
    COMPLETION_WITHOUT_PURCHASE_WAIT = 72.hours

    def self.configured?
      bot_token.present? && channel_id.present?
    end

    def self.bot_token
      ENV["SLACK_BOT_TOKEN"].to_s.strip.presence ||
        ENV["WIZWIKI_COMMS_SLACK_BOT_TOKEN"].to_s.strip.presence ||
        ENV["SLACK_API_TOKEN"].to_s.strip.presence
    end

    def self.channel_id
      ENV["SLACK_COMMS_CHANNEL_ID"].to_s.strip.presence ||
        ENV["WIZWIKI_COMMS_SLACK_CHANNEL_ID"].to_s.strip.presence ||
        ENV["SLACK_APPROVAL_CHANNEL_ID"].to_s.strip.presence ||
        ENV["SLACK_APPROVAL_ID"].to_s.strip.presence ||
        ENV["SLACK_CHANNEL_ID"].to_s.strip.presence
    end

    def self.mentions
      filtered_mentions(ENV["SLACK_COMMS_MENTIONS"].to_s.squish.presence || "@sample_owner")
    end

    def self.owner_mention(owner)
      return if disallowed_owner?(owner)

      name = owner&.display_name.to_s.squish
      email = owner&.email_address.to_s.squish.downcase
      mappings = ENV["SLACK_COMMS_OWNER_MENTIONS"].to_s.split(/[\n,]/).filter_map do |entry|
        key, value = entry.split(":", 2).map { |part| part.to_s.squish }
        [key.downcase, value] if key.present? && value.present?
      end.to_h
      mappings[name.downcase].presence || mappings[email].presence || (name.present? ? "@#{name.split.first}" : nil)
    end

    def self.owner_label(owner)
      return "unassigned" if disallowed_owner?(owner)

      owner&.display_name.to_s.squish.presence ||
        owner&.email_address.to_s.squish.presence ||
        "unassigned"
    end

    def self.owner_context_line(owner)
      return if owner.blank? || disallowed_owner?(owner)

      owner_id = owner.respond_to?(:hubspot_owner_id) ? owner.hubspot_owner_id.to_s.squish.presence : nil
      source = owner.respond_to?(:source) ? owner.source.to_s.squish.presence : nil
      parts = [
        ("HubSpot owner: #{owner_id}" if owner_id.present?),
        ("Source: #{source}" if source.present?)
      ].compact
      parts.present? ? parts.join(" // ") : nil
    end

    def self.post_autopilot_started!(stage:)
      return false unless configured?

      company = stage.metadata.to_h["company_name"].presence || stage.crm_record&.name.to_s.presence || stage.title
      contact = stage.metadata.to_h["captured_contact_name"].presence ||
        stage.metadata.to_h.dig("contact_options", 0, "name").presence ||
        "contact"
      text = [
        mentions,
        "Thumper COMMS BOT running discovery.",
        "Company: #{company}",
        "Contact: #{contact}",
        "Status: autopilot started"
      ].join("\n")

      post_message!(text)
    rescue StandardError => error
      Rails.logger.warn("[Comms::SlackNotifier] autopilot start notify failed stage=#{stage&.id} #{error.class}: #{error.message}")
      false
    end

    def self.post_handoff!(stage:, owner:, reason:)
      return false unless configured?
      owner = safe_owner(owner)
      metadata = stage.metadata.to_h
      return false if metadata["sms_autopilot_slack_human_requested_at"].present? ||
        metadata["sms_autopilot_slack_completion_without_purchase_at"].present? ||
        metadata["sms_autopilot_slack_handoff_at"].present?

      company = company_name(stage)
      contact = contact_name(stage)
      phone = phone_number(stage)
      text = handoff_fallback_text(
        stage: stage,
        owner: owner,
        company: company,
        contact: contact,
        phone: phone,
        reason: reason
      )

      post_message!(text, blocks: handoff_blocks(stage: stage, owner: owner, company: company, contact: contact, phone: phone, reason: reason))
      mark_stage!(stage, "sms_autopilot_slack_handoff_at")
    rescue StandardError => error
      Rails.logger.warn("[Comms::SlackNotifier] handoff failed stage=#{stage&.id} #{error.class}: #{error.message}")
      false
    end

    def self.post_human_requested!(stage:, owner: nil, latest_body: nil, reason: nil)
      return false unless configured?
      return false if stage.metadata.to_h["sms_autopilot_slack_human_requested_at"].present?

      owner = safe_owner(owner) || safe_owner(stage.user)
      company = company_name(stage)
      contact = contact_name(stage)
      phone = phone_number(stage)
      text = handoff_fallback_text(
        stage: stage,
        owner: owner,
        company: company,
        contact: contact,
        phone: phone,
        reason: reason,
        latest_body: latest_body
      )

      post_message!(
        text,
        blocks: handoff_blocks(
          stage: stage,
          owner: owner,
          company: company,
          contact: contact,
          phone: phone,
          reason: reason,
          latest_body: latest_body
        )
      )
      mark_stage!(stage, "sms_autopilot_slack_human_requested_at")
    rescue StandardError => error
      Rails.logger.warn("[Comms::SlackNotifier] human request failed stage=#{stage&.id} #{error.class}: #{error.message}")
      false
    end

    def self.ensure_completion_without_purchase_pending!(stage:, reason: "Thumper completed SMS discovery without purchase evidence.")
      return false if stage.blank?

      stage.reload
      metadata = stage.metadata.to_h.deep_dup
      return false if metadata["sms_autopilot_slack_completion_without_purchase_at"].present?
      return false if purchase_detected?(stage)
      return false unless shopify_link_sent?(stage)

      anchor_at = completion_without_purchase_anchor_at(metadata) || Time.current
      pending_at = parse_time(metadata["sms_autopilot_slack_completion_without_purchase_pending_at"]) || anchor_at
      due_at = parse_time(metadata["sms_autopilot_slack_completion_without_purchase_due_at"]) || pending_at + COMPLETION_WITHOUT_PURCHASE_WAIT

      stage.update!(
        metadata: metadata.merge(
          "sms_autopilot_slack_completion_without_purchase_pending_at" => pending_at.iso8601,
          "sms_autopilot_slack_completion_without_purchase_due_at" => due_at.iso8601,
          "sms_autopilot_slack_completion_without_purchase_reason" => reason.to_s.squish.presence,
          "sms_autopilot_slack_completion_without_purchase_wait_hours" => (COMPLETION_WITHOUT_PURCHASE_WAIT.to_i / 1.hour.to_i)
        ).compact_blank
      )
      true
    rescue StandardError => error
      Rails.logger.warn("[Comms::SlackNotifier] completion pending mark failed stage=#{stage&.id} #{error.class}: #{error.message}")
      false
    end

    def self.completion_without_purchase_due?(stage, now: Time.current)
      return false if stage.blank?

      stage.reload
      metadata = stage.metadata.to_h
      return false if metadata["sms_autopilot_slack_completion_without_purchase_at"].present?
      return false if purchase_detected?(stage)
      return false unless shopify_link_sent?(stage)

      due_at = parse_time(metadata["sms_autopilot_slack_completion_without_purchase_due_at"])
      anchor_at = parse_time(metadata["sms_autopilot_slack_completion_without_purchase_pending_at"]) || completion_without_purchase_anchor_at(metadata)
      due_at ||= anchor_at + COMPLETION_WITHOUT_PURCHASE_WAIT if anchor_at.present?
      due_at.present? && due_at <= now
    end

    def self.post_completion_without_purchase!(stage:, owner: nil, reason: "Thumper completed SMS discovery without purchase evidence.", force: false)
      return false unless configured?
      return false if stage.reload.metadata.to_h["sms_autopilot_slack_completion_without_purchase_at"].present?
      return false if purchase_detected?(stage)
      return false unless shopify_link_sent?(stage)

      unless force || completion_without_purchase_due?(stage)
        ensure_completion_without_purchase_pending!(stage: stage, reason: reason)
        return false
      end

      owner = safe_owner(owner) || safe_owner(stage.user)
      company = company_name(stage)
      contact = contact_name(stage)
      phone = phone_number(stage)
      latest_body = latest_client_sms_body(stage)
      text = handoff_fallback_text(
        stage: stage,
        owner: owner,
        company: company,
        contact: contact,
        phone: phone,
        reason: reason,
        latest_body: latest_body
      )

      post_message!(
        text,
        blocks: handoff_blocks(
          stage: stage,
          owner: owner,
          company: company,
          contact: contact,
          phone: phone,
          reason: reason,
          latest_body: latest_body
        )
      )
      mark_stage!(stage, "sms_autopilot_slack_completion_without_purchase_at")
    rescue StandardError => error
      Rails.logger.warn("[Comms::SlackNotifier] completion notify failed stage=#{stage&.id} #{error.class}: #{error.message}")
      false
    end

    def self.post_message!(text, blocks: nil)
      payload = { channel: channel_id, text: text }
      payload[:blocks] = blocks if blocks.present?
      response = slack_post("chat.postMessage", payload)
      raise Error, response["error"].presence || "Slack post failed" unless response["ok"]

      response
    end

    def self.handoff_fallback_text(stage:, owner:, company:, contact:, phone:, reason:, latest_body: nil)
      email = email_address(stage)
      proof = proof_delivery_context(stage)
      preference = handoff_contact_preference_context(stage)
      [
        ROUND_ROBIN_TITLE,
        "Congratulations #{owner_label(owner)}! :tada:",
        "Company: #{company}",
        "Contact: #{contact}",
        ("Phone: #{phone}" if phone.present?),
        ("Email: #{email}" if email.present?),
        ("Client contact preference: #{preference}" if preference.present?),
        ("Proof delivery: #{proof}" if proof.present?),
        ("Link: #{thumper_call_block_link(stage)}" if thumper_call_block_link(stage).present?),
        ("Client said: #{latest_body.to_s.squish.truncate(220)}" if latest_body.to_s.squish.present?),
        "Reason: #{handoff_reason_label(reason)} :magic_wand::rabbit2:"
      ].compact.join("\n")
    end

    def self.handoff_blocks(stage:, owner:, company:, contact:, phone:, reason:, latest_body: nil)
      email = email_address(stage)
      proof = proof_delivery_context(stage)
      preference = handoff_contact_preference_context(stage)
      headline = [
        "*Congratulations #{slack_escape(owner_label(owner))}!* :tada:"
      ].compact.join("\n")
      fields = [
        "*Company:*\n#{slack_escape(company)}",
        "*Contact:*\n#{slack_escape(contact)}",
        ("*Phone:*\n`#{slack_escape(phone)}`" if phone.present?),
        ("*Email:*\n#{slack_escape(email)}" if email.present?)
      ].compact
      body = [
        ("*Client contact preference:* #{slack_escape(preference)}" if preference.present?),
        ("*Proof delivery:* #{slack_escape(proof)}" if proof.present?),
        ("*Link:* #{thumper_call_block_link(stage)}" if thumper_call_block_link(stage).present?),
        ("*Client said:*\n#{slack_escape(latest_body.to_s.squish.truncate(220))}" if latest_body.to_s.squish.present?),
        "*Reason:* #{slack_escape(handoff_reason_label(reason))} :magic_wand::rabbit2:"
      ].compact.join("\n")

      blocks = [
        {
          type: "header",
          text: { type: "plain_text", text: ROUND_ROBIN_TITLE, emoji: true }
        },
        {
          type: "section",
          text: { type: "mrkdwn", text: headline }
        }
      ]
      blocks << { type: "section", fields: fields.map { |field| { type: "mrkdwn", text: field } } } if fields.present?
      blocks << { type: "section", text: { type: "mrkdwn", text: body } } if body.present?
      blocks
    end

    def self.handoff_contact_preference_context(stage)
      metadata = stage.reload.metadata.to_h
      preference = metadata["sms_autopilot_handoff_contact_preference"].to_s.squish.presence
      email = metadata["sms_autopilot_handoff_contact_email"].to_s.squish.presence
      phone = metadata["sms_autopilot_handoff_contact_phone"].to_s.squish.presence
      time = metadata["sms_autopilot_handoff_contact_time"].to_s.squish.presence
      effective_window = metadata["sms_autopilot_handoff_contact_effective_window"].to_s.squish.presence

      parts = []
      parts << preference_label(preference) if preference.present?
      parts << email if email.present?
      parts << phone if phone.present?
      parts << "customer said: #{time}" if time.present?
      parts << "scheduled: #{effective_window}" if effective_window.present?
      parts.join(" / ").presence
    end

    def self.preference_label(value)
      case value.to_s
      when "email" then "email"
      when "call", "phone" then "phone call"
      when "text", "sms" then "text"
      else value.to_s
      end
    end

    def self.handoff_reason_label(reason)
      text = reason.to_s.squish
      return "AM support requested from WIZWIKI COMMS." if text.blank?
      return text if text.include?(" ") && !text.match?(/\A[a-z_]+\z/)

      case text
      when /manual_am_support/
        "Manual AM help requested from WIZWIKI COMMS."
      when /proof|artwork_proof|design_proof/
        "Client needs design/proof handoff and proof delivery details."
      when /rush_or_deadline/
        "Customer requested rush or a hard deadline that needs live production confirmation."
      when /account_manager_answer_needed/
        "Customer needs AM support before the next SMS."
      when /starter_pack_over_limit/
        "Client may need larger-volume specials beyond a few Starter Pack bundles."
      when /human_requested/
        "Customer requested a human from WIZWIKI COMMS."
      when /completion_without_purchase/
        "Thumper completed discovery and needs AM follow-up."
      else
        text.tr("_", " ").capitalize
      end
    end

    def self.thumper_call_block_link(stage)
      url = comms_card_url(stage)
      return if url.blank?

      "<#{url}|Thumper CALL BLOCK>"
    end

    def self.slack_escape(value)
      value.to_s.gsub("&", "&amp;").gsub("<", "&lt;").gsub(">", "&gt;")
    end

    def self.permalink(channel:, ts:)
      response = slack_post("chat.getPermalink", channel: channel, message_ts: ts)
      response["ok"] ? response["permalink"] : nil
    end

    def self.slack_post(path, payload)
      uri = URI("https://slack.com/api/#{path}")
      request = Net::HTTP::Post.new(uri)
      request["Authorization"] = "Bearer #{bot_token}"
      request["Content-Type"] = "application/json; charset=utf-8"
      request.body = JSON.generate(payload)
      response = Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: 10, read_timeout: 20) do |http|
        http.request(request)
      end
      JSON.parse(response.body)
    rescue JSON::ParserError
      { "ok" => false, "error" => "invalid_json_response" }
    end

    def self.company_name(stage)
      metadata = stage.metadata.to_h
      selected = selected_contact(stage)
      first_identity_value(
        metadata["captured_company_name"],
        metadata.dig("comms_bot_state", "company_name"),
        selected["company"],
        metadata["company_name"],
        stage.crm_record&.properties.to_h["company"],
        stage.crm_record&.name,
        stage.title
      ) || "Not captured yet"
    end

    def self.contact_name(stage)
      metadata = stage.metadata.to_h
      selected = selected_contact(stage)
      first_identity_value(
        metadata["captured_contact_name"],
        metadata.dig("comms_bot_state", "contact_name"),
        selected["name"],
        metadata["contact_name"]
      ) || "Not captured yet"
    end

    def self.phone_number(stage)
      stage.metadata.to_h.dig("phone_options", 0, "value").presence || stage.crm_record&.phone
    end

    def self.email_address(stage)
      metadata = stage.metadata.to_h
      selected = selected_email(stage)
      first_identity_value(
        metadata["proof_delivery_email"],
        metadata["captured_email"],
        metadata["recipient_email"],
        metadata.dig("aircall_selected_recipient_email", "email"),
        metadata.dig("aircall_selected_recipient_email", "value"),
        selected["email"],
        selected["value"],
        stage.crm_record&.properties.to_h["email"],
        stage.crm_record&.properties.to_h["hs_email"]
      )
    end

    def self.proof_delivery_context(stage)
      metadata = stage.metadata.to_h
      parts = []
      method = metadata["proof_delivery_method"].to_s.squish.presence
      email = metadata["proof_delivery_email"].presence || email_address(stage)
      contact_preference = metadata["contact_preference"].to_s.squish.presence
      window = metadata["preferred_contact_window"].to_s.squish.presence ||
        metadata["preferred_contact_days"].to_s.squish.presence ||
        metadata["preferred_contact_times"].to_s.squish.presence

      parts << "method #{method}" if method.present?
      parts << "email #{email}" if email.present?
      parts << "contact #{contact_preference}" if contact_preference.present? && contact_preference != method
      parts << "window #{window}" if window.present?
      parts.presence&.join(" // ")
    end

    def self.selected_email(stage)
      metadata = stage.metadata.to_h
      selected_id = metadata["selected_recipient_email_id"].to_s
      options = Array(metadata["recipient_email_options"])
      selected = options.find { |option| option.to_h["id"].to_s == selected_id }
      (selected || options.first || {}).to_h
    end

    def self.selected_contact(stage)
      metadata = stage.metadata.to_h
      selected_id = metadata["selected_contact_id"].to_s
      options = Array(metadata["contact_options"])
      selected = options.find { |option| option.to_h["id"].to_s == selected_id }
      (selected || options.first || {}).to_h
    end

    def self.first_identity_value(*values)
      values.flatten.find do |value|
        identity_value(value).present?
      end.then { |value| identity_value(value) }
    end

    def self.identity_value(value)
      text = value.to_s.squish
      return if generic_comms_identity?(text)

      text.presence
    end

    def self.generic_comms_identity?(value)
      text = value.to_s.squish.downcase
      text.blank? ||
        %w[wizwiki\ comms sample\ comms manual\ comms choose\ in\ lab contact customer].include?(text) ||
        text.match?(/\A(?:wizwiki\s*)?comms\b/) ||
        text.match?(/\Asample\b/)
    end

    def self.record_links_line(stage)
      links = record_links(stage)
      return if links.blank?

      "Links: #{links.join(' | ')}"
    end

    def self.record_links(stage)
      metadata = stage.metadata.to_h
      links = []
      links << "<#{comms_card_url(stage)}|Open WIZWIKI COMMS card>" if comms_card_url(stage).present?
      links << "<#{sms_station_url(stage)}|Open SMS station>" if sms_station_url(stage).present?
      hubspot_links = []
      if (lead_id = hubspot_lead_id(stage, metadata)).present? && (url = hubspot_lead_url(stage, metadata)).present?
        hubspot_links << "<#{url}|HubSpot lead #{lead_id}>"
      end
      if (contact_id = hubspot_contact_id(stage, metadata)).present? && (url = hubspot_url(stage, metadata)).present?
        hubspot_links << "<#{url}|HubSpot contact #{contact_id}>"
      end
      links.concat(hubspot_links)
      links << "<#{local_crm_url(stage)}|WIZWIKI CRM>" if hubspot_links.blank? && local_crm_url(stage).present?
      links.compact.uniq
    end

    def self.comms_card_url(stage)
      return if stage.id.blank?

      "#{public_base_url}/leads/comms?open_stage=#{stage.id}#stage-#{stage.id}"
    end

    def self.sms_station_url(stage)
      return if stage.id.blank?

      "#{public_base_url}/leads/comms?status=am_support&open_sms_stage=#{stage.id}#stage-#{stage.id}"
    end

    def self.public_base_url
      (ENV["WIZWIKI_PUBLIC_URL"].presence || ENV["APP_HOST"].presence || "https://wizwiki.local").to_s.chomp("/")
    end

    def self.local_crm_url(stage)
      base = public_base_url
      return if stage.crm_record_id.blank?

      "#{base.to_s.chomp('/')}/crm/records/#{stage.crm_record_id}"
    end

    def self.hubspot_url(stage, metadata)
      portal = hubspot_portal_id
      contact_id = hubspot_contact_id(stage, metadata)
      return if portal.blank? || contact_id.blank?

      "https://app.hubspot.com/contacts/#{portal}/record/0-1/#{contact_id}"
    end

    def self.hubspot_contact_id(stage, metadata)
      properties = stage.crm_record&.properties.to_h
      hubspot_object_id(first_present(
        metadata["hubspot_contact_id"],
        metadata.dig("hubspot_lead", "hubspot_contact_id"),
        metadata.dig("hubspot_lead", "associated_contact_id"),
        metadata.dig("hubspot_lead", "contact_id"),
        metadata.dig("manual_comms_hubspot_lead", "hubspot_contact_id"),
        metadata.dig("manual_comms_hubspot_lead", "associated_contact_id"),
        metadata.dig("manual_comms_hubspot_lead", "contact_id"),
        metadata.dig("csv_call_raw_row", "hubspot_contact_id"),
        metadata.dig("csv_call_raw_row", "associated_contact_id"),
        metadata.dig("csv_call_raw_row", "associated_contact_ids_primary"),
        metadata.dig("csv_call_raw_row", "associated_contact_primary"),
        metadata.dig("csv_call_raw_row", "associated_contact"),
        metadata.dig("csv_call_raw_row", "contact", "id"),
        metadata.dig("csv_call_raw_row", "contact", "properties", "hs_object_id"),
        properties.dig("manual_comms_hubspot_lead", "hubspot_contact_id"),
        properties.dig("manual_comms_hubspot_lead", "associated_contact_id"),
        properties.dig("manual_comms_hubspot_lead", "contact_id"),
        properties.dig("manual_comms_raw_row", "associated_contact_id"),
        properties.dig("manual_comms_raw_row", "associated_contact_ids_primary"),
        properties.dig("manual_comms_raw_row", "associated_contact_primary"),
        properties.dig("manual_comms_raw_row", "contact", "id"),
        properties.dig("manual_comms_raw_row", "contact", "properties", "hs_object_id"),
        properties.dig("hubspot", "id"),
        properties.dig("hubspot", "properties", "hs_object_id"),
        stage.crm_record&.source.to_s == "hubspot_contact" ? stage.crm_record&.source_uid : nil
      ))
    end

    def self.hubspot_lead_url(stage, metadata)
      portal = hubspot_portal_id
      lead_id = hubspot_lead_id(stage, metadata)
      return if portal.blank? || lead_id.blank?

      "https://app.hubspot.com/contacts/#{portal}/record/0-136/#{lead_id}"
    end

    def self.hubspot_lead_id(stage, metadata)
      properties = stage.crm_record&.properties.to_h
      hubspot_object_id(first_present(
        metadata["hubspot_lead_id"],
        metadata.dig("hubspot_lead", "hubspot_lead_id"),
        metadata.dig("hubspot_lead", "hs_object_id"),
        metadata.dig("hubspot_lead", "id"),
        metadata.dig("manual_comms_hubspot_lead", "hubspot_lead_id"),
        metadata.dig("csv_call_raw_row", "hubspot_lead_id"),
        metadata.dig("csv_call_raw_row", "record_id"),
        metadata.dig("csv_call_raw_row", "lead_id"),
        metadata.dig("csv_call_raw_row", "hs_object_id"),
        metadata.dig("csv_call_raw_row", "lead", "id"),
        metadata.dig("csv_call_raw_row", "lead", "properties", "hs_object_id"),
        properties.dig("manual_comms_hubspot_lead", "hubspot_lead_id"),
        properties.dig("manual_comms_raw_row", "hubspot_lead_id"),
        properties.dig("manual_comms_raw_row", "record_id"),
        properties.dig("manual_comms_raw_row", "lead_id"),
        properties.dig("manual_comms_raw_row", "hs_object_id"),
        properties.dig("manual_comms_raw_row", "lead", "id"),
        properties.dig("manual_comms_raw_row", "lead", "properties", "hs_object_id"),
        stage.crm_record&.source.to_s == "hubspot_lead" ? stage.crm_record&.source_uid : nil
      ))
    end

    def self.hubspot_portal_id
      ENV["HUBSPOT_PORTAL_ID"].presence || ENV["HUBSPOT_ACCOUNT_ID"].presence || fetched_hubspot_portal_id
    end

    def self.fetched_hubspot_portal_id
      return unless defined?(Hubspot::Client)

      Rails.cache.fetch("comms/slack/hubspot_portal_id", expires_in: 12.hours) do
        details = Hubspot::Client.new.get("/account-info/v3/details")
        details["portalId"].presence || details["hubId"].presence
      end
    rescue StandardError => error
      Rails.logger.warn("[Comms::SlackNotifier] HubSpot portal lookup failed #{error.class}: #{error.message}")
      nil
    end

    def self.first_present(*values)
      values.flatten.compact.map { |value| value.to_s.squish.presence }.compact.first
    end

    def self.hubspot_object_id(value)
      text = value.to_s.squish
      return if text.blank?

      text[%r{/record/0-\d+/(\d+)}, 1].presence ||
        text[/\b\d{3,}\b/].presence ||
        (text.match?(/\A\d+\z/) ? text : nil)
    end

    def self.mark_stage!(stage, key)
      metadata = stage.reload.metadata.to_h.deep_dup
      stage.update!(
        metadata: metadata.merge(
          key => Time.current.iso8601,
          "comms_support_state" => "am_support",
          "comms_support_state_at" => metadata["comms_support_state_at"].presence || Time.current.iso8601
        )
      )
      true
    end

    def self.safe_owner(owner)
      disallowed_owner?(owner) ? nil : owner
    end

    def self.disallowed_owner?(owner)
      return false if owner.blank?

      [
        (owner.respond_to?(:display_name) ? owner.display_name : nil),
        (owner.respond_to?(:email_address) ? owner.email_address : nil),
        (owner.respond_to?(:email) ? owner.email : nil),
        (owner.respond_to?(:id) ? owner.id : nil)
      ].any? { |value| disallowed_owner_value?(value) }
    end

    def self.disallowed_owner_value?(value)
      text = value.to_s.squish.downcase
      text.start_with?("ethan") || text.include?("ethan@")
    end

    def self.filtered_mentions(raw_mentions)
      raw_mentions.to_s.split(/\s+/).reject { |mention| disallowed_owner_value?(mention.delete_prefix("@")) }.join(" ").presence || "@sample_owner"
    end

    def self.purchase_detected?(stage)
      record = stage.crm_record
      record.reload if record.present?
      purchase_value?(stage.reload.metadata) || purchase_value?(record&.properties)
    end

    def self.shopify_link_sent?(stage)
      metadata = stage.reload.metadata.to_h
      return true if metadata["shopify_link_sent_at"].present? || metadata["comms_link_reached_at"].present?

      shopify_links = metadata["shopify_links"].respond_to?(:to_h) ? metadata["shopify_links"].to_h : {}
      links = [metadata["shopify_link"].to_s.squish, shopify_links.values].flatten.compact_blank.map(&:to_s)

      Array(metadata["sms_thread"]).any? do |event|
        event = event.to_h
        next false unless event["channel"].to_s.blank? || event["channel"].to_s == "sms"
        next false unless event["direction"].to_s == "outbound"
        next false if event["status"].to_s.in?(%w[failed canceled])

        body = event["body"].to_s
        links.any? { |link| link.present? && body.include?(link) } ||
          body.match?(%r{https?://\S*(?:shopify|shop\.wizwikimarketing|wizwikimarketing\.com/products)\S*}i)
      end
    end

    def self.completion_without_purchase_anchor_at(metadata)
      [
        metadata["sms_autopilot_slack_completion_without_purchase_pending_at"],
        metadata["sms_autopilot_completion_sent_at"],
        metadata["sms_autopilot_completed_at"],
        metadata.dig("comms_bot_state", "autopilot_completed_at"),
        metadata["shopify_link_sent_at"],
        metadata["comms_link_reached_at"]
      ].filter_map { |value| parse_time(value) }.min
    end

    def self.latest_client_sms_body(stage)
      Array(stage.metadata.to_h["sms_thread"]).reverse_each do |event|
        event = event.to_h
        next unless event["direction"].to_s == "inbound"

        body = event["body"].to_s.squish
        return body if body.present?
      end
      nil
    end

    def self.parse_time(value)
      Time.zone.parse(value.to_s)
    rescue ArgumentError, TypeError
      nil
    end

    def self.purchase_value?(value, key_hint = nil)
      case value
      when Hash
        value.any? { |key, item| purchase_value?(item, key.to_s.downcase) }
      when Array
        value.any? { |item| purchase_value?(item, key_hint) }
      else
        text = value.to_s.squish
        return false if text.blank?

        key = key_hint.to_s
        commerce_key = key.match?(/shopify|order|checkout|purchase|paid|payment|square|receipt|transaction/)
        return text.to_i.positive? if key.match?(/orders?_count/)
        return text.to_f.positive? if key.match?(/amount_spent/) || (commerce_key && key.match?(/total|subtotal|revenue|paid|payment|amount/))
        return true if commerce_key && key.match?(/order.*id|checkout.*completed|purchase.*(?:at|id)|paid_at|receipt|transaction/) && !text.in?(%w[0 false no none null])

        false
      end
    end
  end
end
