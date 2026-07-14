module DealReports
  class ContactIntelligence
    EMAIL_PATTERN = /[A-Z0-9._%+\-]+@[A-Z0-9.\-]+\.[A-Z]{2,}/i
    PHONE_KEY_PATTERN = /phone|mobile|cell|tel/i
    EMAIL_KEY_PATTERN = /email/i
    DECISION_TITLE_PATTERN = /owner|founder|president|principal|ceo|chief|marketing|manager|director|partner|decision|operations|sales/i
    RECENT_WINDOW = 90.days

    def self.for_record(crm_record, direction: "wizwiki_out")
      new(crm_record, direction: direction).payload
    end

    def initialize(crm_record, direction:)
      @crm_record = crm_record
      @direction = direction.to_s == "client_out" ? "client_out" : "wizwiki_out"
    end

    def payload
      ranked_contacts = candidate_records.map { |record, edge| candidate_for(record, edge) }
        .compact
        .sort_by { |item| [-item.fetch("score").to_i, item.fetch("rank_name").to_s] }
        .first(12)
        .map.with_index(1) { |item, index| item.merge("rank" => index).except("rank_name") }

      phone_options = ranked_contacts.flat_map { |candidate| phone_options_for(candidate) }.first(12)
      email_options = ranked_contacts.flat_map { |candidate| email_options_for(candidate) }.first(12)
      address_options = ranked_contacts.flat_map { |candidate| address_options_for(candidate) }.first(18)
      selected_contact = ranked_contacts.find { |candidate| candidate["phone_values"].present? || candidate["email_values"].present? } || ranked_contacts.first
      selected_phone = phone_options.first
      selected_email = email_options.first
      selected_address = address_options.find { |option| option["contact_id"] == selected_contact&.fetch("id", nil) } || address_options.first

      {
        "direction" => @direction,
        "direction_label" => @direction == "client_out" ? "CLIENT OUT" : "WIZWIKI OUT",
        "source" => "associated CRM records, normalized contact fields, HubSpot labeled/raw fields, and recent playbook calls",
        "ranking_note" => ranking_note,
        "ranked_contacts" => ranked_contacts,
        "phone_options" => phone_options,
        "email_options" => email_options,
        "address_options" => address_options,
        "selected_contact_id" => selected_contact&.fetch("id", nil),
        "selected_phone_id" => selected_phone&.fetch("id", nil),
        "selected_email_id" => selected_email&.fetch("id", nil),
        "selected_address_id" => selected_address&.fetch("id", nil),
        "selected_summary" => selected_summary(selected_contact, selected_phone, selected_email, selected_address),
        "generated_at" => Time.current.iso8601
      }
    end

    private

    def ranking_note
      if @direction == "client_out"
        "CLIENT OUT uses these contacts as source context, but final delivery should usually target the client's own CRM list. Pick a contact only when staging a direct one-to-one message."
      else
        "WIZWIKI OUT ranks likely business decision-makers using association type, available phone/email, title, lifecycle, recent communications, and CRM freshness."
      end
    end

    def candidate_records
      pairs = [[@crm_record, nil]]
      association_edges.each { |edge| pairs << [edge.fetch(:record), edge] if edge.fetch(:record, nil).present? }
      seen = {}
      pairs.select do |record, edge|
        key = [record.id, edge&.dig(:association)&.association_type]
        next false if seen[key]

        seen[key] = true
      end
    end

    def association_edges
      edges = []
      @crm_record.outbound_associations.includes(:to_record).each do |association|
        edges << { association: association, record: association.to_record, direction: "outbound" }
      end
      @crm_record.inbound_associations.includes(:from_record).each do |association|
        edges << { association: association, record: association.from_record, direction: "inbound" }
      end
      edges
    end

    def candidate_for(record, edge)
      hubspot = record.properties.to_h.fetch("hubspot", {}).to_h
      raw = hubspot.fetch("properties", {}).to_h
      labeled = hubspot.fetch("labeled_properties", {}).to_h
      emails = extract_emails(record, raw, labeled)
      phones = extract_phones(record, raw, labeled)
      addresses = extract_addresses(record, raw, labeled)
      return nil if emails.blank? && phones.blank? && record.record_type != "contact"

      title = first_present(labeled["Job Title"], raw["jobtitle"], raw["hs_job_title"], labeled["Title"])
      lifecycle = first_present(labeled["Lifecycle Stage"], raw["lifecyclestage"])
      company = first_present(labeled["Company"], raw["company"], raw["company_name"], raw["associatedcompanyid"])
      status = first_present(labeled["Ticket Status"], labeled["Deal Stage"], raw["hs_pipeline_stage"], raw["dealstage"], raw["hs_ticket_priority"], record.status)
      amount = first_present(raw["amount"], raw["deal_amount"], raw["hs_deal_amount"], labeled["Amount"])
      recent_call = latest_call_for(record)
      recent_at = most_recent_time(record, recent_call, raw, labeled)
      reasons = []
      score = 0

      if record.record_type == "contact"
        score += 35
        reasons << "contact record"
      elsif record.record_type == "company"
        score += 15
        reasons << "company record"
      end

      association_type = edge&.dig(:association)&.association_type
      if association_type.present?
        score += association_score(association_type)
        reasons << "#{association_type.humanize.downcase} association"
      end

      if emails.present?
        score += 12
        reasons << "email present"
      end
      if phones.present?
        score += 16
        reasons << "phone present"
      end
      if emails.present? && phones.present?
        score += 10
        reasons << "phone and email both present"
      end
      if addresses.present?
        score += 4
        reasons << "address present"
      end
      if title.to_s.match?(DECISION_TITLE_PATTERN)
        score += 18
        reasons << "decision-maker title"
      end
      if lifecycle.to_s.match?(/lead|opportunity|customer|subscriber/i)
        score += 6
        reasons << "active lifecycle"
      end
      if recent_call
        score += 24
        reasons << "recent playbook communication"
      elsif recent_at && recent_at > RECENT_WINDOW.ago
        score += 10
        reasons << "recent CRM activity"
      end

      {
        "id" => "crm_#{record.id}",
        "record_id" => record.id,
        "record_type" => record.record_type,
        "name" => record.name,
        "title" => title,
        "company" => company,
        "association_type" => association_type,
        "association_direction" => edge&.dig(:direction),
        "lifecycle" => lifecycle,
        "email_values" => emails,
        "phone_values" => phones,
        "address_values" => addresses,
        "status" => status,
        "amount" => amount,
        "recent_communication_at" => recent_at&.iso8601,
        "recent_communication_summary" => recent_call&.compact_context(max_chars: 260),
        "relationship_signals" => relationship_signals(record, labeled, raw, recent_call),
        "score" => score,
        "reason" => reasons.uniq.join(" + "),
        "rank_name" => record.name.to_s.downcase
      }
    end

    def association_score(value)
      case value.to_s
      when "buyer", "requester" then 26
      when "primary_company" then 16
      when "collaborator" then 10
      else 6
      end
    end

    def latest_call_for(record)
      @latest_call_by_record_id ||= PlaybookCall.for_crm_record_graph(@crm_record).limit(25).to_a
        .group_by(&:crm_record_id)
        .transform_values { |calls| calls.compact.max_by { |call| call.occurred_at || call.updated_at || call.created_at } }
      @latest_call_by_record_id[record.id]
    rescue StandardError
      nil
    end

    def most_recent_time(record, recent_call, raw, labeled)
      [
        recent_call&.occurred_at,
        parse_time(first_present(raw["hs_lastmodifieddate"], raw["lastmodifieddate"], raw["notes_last_updated"], raw["hs_email_last_send_date"], raw["hs_sales_email_last_replied"], labeled["Last Contacted"])),
        record.updated_at
      ].compact.max
    end

    def extract_emails(record, raw, labeled)
      values = []
      values << record.email
      values.concat(values_for_matching_keys(raw, EMAIL_KEY_PATTERN))
      values.concat(values_for_matching_keys(labeled, EMAIL_KEY_PATTERN))
      values.flat_map { |value| value.to_s.scan(EMAIL_PATTERN) }
        .map { |value| value.to_s.strip.downcase }
        .uniq
        .first(5)
    end

    def extract_phones(record, raw, labeled)
      values = []
      values << record.phone
      values.concat(values_for_matching_keys(raw, PHONE_KEY_PATTERN))
      values.concat(values_for_matching_keys(labeled, PHONE_KEY_PATTERN))
      values.map { |value| normalize_phone(value) }
        .compact
        .uniq
        .first(5)
    end

    def extract_addresses(record, raw, labeled)
      values = record.crm_address_records.sorted.limit(5).map(&:display_address)
      values << formatted_property_address(raw)
      values << formatted_property_address(labeled)
      values.compact_blank.map { |value| value.to_s.squish }.uniq.first(5)
    end

    def formatted_property_address(hash)
      address1 = first_present(hash["address"], hash["address1"], hash["address_1"], hash["street_address"], hash["Street Address"], hash["Address"])
      address2 = first_present(hash["address2"], hash["address_2"], hash["unit"], hash["suite"])
      city = first_present(hash["city"], hash["City"])
      state = first_present(hash["state"], hash["state_dd"], hash["State"])
      postal = first_present(hash["zip"], hash["postal_code"], hash["Postal Code"], hash["Zip"])
      country = first_present(hash["country"], hash["Country"])

      [
        [address1, address2].compact_blank.join(" "),
        [city, state, postal].compact_blank.join(", "),
        country
      ].compact_blank.join(" | ").presence
    end

    def values_for_matching_keys(hash, pattern)
      hash.to_h.each_with_object([]) do |(key, value), values|
        next unless key.to_s.match?(pattern)

        if value.is_a?(Array)
          values.concat(value)
        else
          values << value
        end
      end
    end

    def normalize_phone(value)
      raw = value.to_s.strip
      return nil if raw.blank?

      digits = raw.gsub(/[^\d+]/, "")
      numeric_count = digits.gsub(/[^\d]/, "").length
      return nil if numeric_count < 7

      digits
    end

    def phone_options_for(candidate)
      candidate.fetch("phone_values", []).map.with_index(1) do |phone, index|
        {
          "id" => "#{candidate.fetch("id")}_phone_#{index}",
          "contact_id" => candidate.fetch("id"),
          "record_id" => candidate.fetch("record_id"),
          "name" => candidate.fetch("name"),
          "value" => phone,
          "label" => "#{candidate.fetch("name")} // #{phone}",
          "rank" => candidate.fetch("rank"),
          "reason" => candidate.fetch("reason")
        }
      end
    end

    def email_options_for(candidate)
      candidate.fetch("email_values", []).map.with_index(1) do |email, index|
        {
          "id" => "#{candidate.fetch("id")}_email_#{index}",
          "contact_id" => candidate.fetch("id"),
          "record_id" => candidate.fetch("record_id"),
          "name" => candidate.fetch("name"),
          "value" => email,
          "label" => "#{candidate.fetch("name")} // #{email}",
          "rank" => candidate.fetch("rank"),
          "reason" => candidate.fetch("reason")
        }
      end
    end

    def address_options_for(candidate)
      candidate.fetch("address_values", []).map.with_index(1) do |address, index|
        {
          "id" => "#{candidate.fetch("id")}_address_#{index}",
          "contact_id" => candidate.fetch("id"),
          "record_id" => candidate.fetch("record_id"),
          "name" => candidate.fetch("name"),
          "value" => address,
          "label" => "#{candidate.fetch("name")} // #{address}",
          "rank" => candidate.fetch("rank"),
          "reason" => candidate.fetch("reason")
        }
      end
    end

    def relationship_signals(record, labeled, raw, recent_call)
      signals = []
      stage = first_present(labeled["Deal Stage"], labeled["Ticket Status"], raw["dealstage"], raw["hs_pipeline_stage"], record.status)
      source = first_present(labeled["Latest Traffic Source"], raw["hs_analytics_latest_source"], raw["hs_analytics_source"], raw["source_type"])
      description = first_present(labeled["Deal Description"], labeled["Ticket Description"], raw["deal_description"], raw["content"])
      signals << "stage/status: #{stage}" if stage.present?
      signals << "source: #{source}" if source.present?
      signals << "recent call: #{recent_call.compact_context(max_chars: 140)}" if recent_call
      signals << "note: #{description.to_s.squish.truncate(180)}" if description.present?
      signals.uniq.first(4)
    end

    def selected_summary(contact, phone, email, address)
      return "No associated contact candidate found." if contact.blank?

      parts = []
      parts << "Best contact: #{contact["name"]}"
      parts << contact["title"] if contact["title"].present?
      parts << "association: #{contact["association_type"]}" if contact["association_type"].present?
      parts << "phone: #{phone["name"]}" if phone.present?
      parts << "email: #{email["name"]}" if email.present?
      parts << "address on file" if address.present?
      parts << "reason: #{contact["reason"]}" if contact["reason"].present?
      parts.join(" // ")
    end

    def first_present(*values)
      values.find(&:present?)
    end

    def parse_time(value)
      return value if value.is_a?(Time)
      return nil if value.blank?

      Time.zone.parse(value.to_s)
    rescue ArgumentError, TypeError
      nil
    end
  end
end
