module Crm
  class AddressExtractor
    MAX_DEPTH = 8
    SKIPPED_PATH_PARTS = %w[property_labels label_property_names labels].freeze

    ADDRESS1_KEYS = %w[
      address address1 address_1 addressline1 address_line_1 street streetaddress street_address
      shippingaddress shipping_address billingaddress billing_address mailingaddress mailing_address
      propertyaddress property_address serviceaddress service_address jobaddress job_address
      siteaddress site_address location bcr_location_as_shown_in_jobnimbus
    ].freeze
    ADDRESS2_KEYS = %w[address2 address_2 addressline2 address_line_2 suite unit apt apartment].freeze
    CITY_KEYS = %w[city shippingcity shipping_city billingcity billing_city town municipality].freeze
    STATE_KEYS = %w[state state_dd province region shippingstate shipping_state billingstate billing_state].freeze
    POSTAL_KEYS = %w[zip zipcode zip_code postal postalcode postal_code shippingzip shipping_zip order_zip nhb_target_zip_code nhb___target_zip_code].freeze
    COUNTRY_KEYS = %w[country shippingcountry shipping_country billingcountry billing_country].freeze
    FREE_TEXT_KEYS = %w[content description notes ticket_description ticketdescription].freeze
    STREET_ADDRESS_PATTERN = /\b\d{2,6}\s+(?:[A-Za-z0-9.-]+\s+){1,8}(?:Street|St\.?|Avenue|Ave\.?|Road|Rd\.?|Drive|Dr\.?|Lane|Ln\.?|Boulevard|Blvd\.?|Court|Ct\.?|Way|Trail|Trl\.?|Circle|Cir\.?)\b/i

    Candidate = Data.define(
      :address_kind,
      :address1,
      :address2,
      :city,
      :state,
      :postal_code,
      :country,
      :address_line,
      :address_one_line,
      :normalized_key,
      :confidence,
      :raw_components,
      :source_path,
      :source_label,
      :metadata
    )

    def self.call(payload, label_map: {})
      new(payload, label_map: label_map).call
    end

    def initialize(payload, label_map: {})
      @payload = payload
      @label_map = label_map.to_h
      @candidates = {}
    end

    def call
      scan(payload, [])
      candidates.values
    end

    private

    attr_reader :payload, :label_map, :candidates

    def scan(value, path)
      return if path.length > MAX_DEPTH

      case value
      when Hash
        candidate = candidate_from_hash(value, path)
        candidates[candidate.normalized_key] ||= candidate if candidate.present?

        value.each do |key, child|
          next_path = path + [key.to_s]
          next if skipped_path?(next_path)

          if child.is_a?(Hash) || child.is_a?(Array)
            scan(child, next_path)
          else
            text_candidate = candidate_from_text(child, next_path)
            candidates[text_candidate.normalized_key] ||= text_candidate if text_candidate.present?
          end
        end
      when Array
        value.first(50).each_with_index do |child, index|
          scan(child, path + [index.to_s]) if child.is_a?(Hash) || child.is_a?(Array)
        end
      end
    end

    def candidate_from_text(value, path)
      return nil unless free_text_path?(path)

      text = value.to_s.gsub(/\s+/, " ").strip
      match = text[STREET_ADDRESS_PATTERN].to_s.strip
      return nil if match.blank?
      return nil if match.match?(/\b(inc|llc|ltd|corp|corporation)\.?\b/i)

      key = normalize_key(match)
      return nil if key.blank?

      Candidate.new(
        address_kind: "address",
        address1: match,
        address2: nil,
        city: nil,
        state: nil,
        postal_code: nil,
        country: nil,
        address_line: match,
        address_one_line: match,
        normalized_key: key,
        confidence: 55,
        raw_components: { address1: match },
        source_path: [path.join("."), "free_text_address"].join("#"),
        source_label: path.last.to_s.titleize,
        metadata: { extractor: "crm/address_extractor", path: path.join("."), extraction_mode: "free_text" }
      )
    end

    def candidate_from_hash(hash, path)
      normalized_hash = normalize_hash_keys(hash)
      address1 = value_for(normalized_hash, ADDRESS1_KEYS)
      address2 = value_for(normalized_hash, ADDRESS2_KEYS)
      city = value_for(normalized_hash, CITY_KEYS)
      state = value_for(normalized_hash, STATE_KEYS)
      postal_code = value_for(normalized_hash, POSTAL_KEYS)
      country = value_for(normalized_hash, COUNTRY_KEYS)

      address_line = address1
      address_kind = "address"
      confidence = 50

      if address1.present?
        confidence = city.present? || state.present? || postal_code.present? ? 90 : 75
      elsif city.present? && (state.present? || country.present?)
        address_kind = "locality"
        confidence = 45
      elsif postal_code.present?
        address_kind = "postal_area"
        confidence = 40
      else
        return nil
      end

      one_line = format_address(
        address1: address1,
        address2: address2,
        city: city,
        state: state,
        postal_code: postal_code,
        country: country
      )
      key = normalize_key(one_line)
      return nil if key.blank?

      raw_components = {
        address1: address1,
        address2: address2,
        city: city,
        state: state,
        postal_code: postal_code,
        country: country
      }.compact_blank

      Candidate.new(
        address_kind: address_kind,
        address1: address1,
        address2: address2,
        city: city,
        state: state,
        postal_code: postal_code,
        country: country,
        address_line: address_line,
        address_one_line: one_line,
        normalized_key: key,
        confidence: confidence,
        raw_components: raw_components,
        source_path: source_path(path, raw_components),
        source_label: source_label(raw_components),
        metadata: { extractor: "crm/address_extractor", path: path.join(".") }
      )
    end

    def normalize_hash_keys(hash)
      hash.each_with_object({}) do |(key, value), memo|
        normalized = normalize_field_name(key)
        next if normalized.blank?

        memo[normalized] ||= clean_value(value)
      end
    end

    def value_for(hash, aliases)
      aliases.each do |key|
        value = hash[normalize_field_name(key)]
        return value if value.present?
      end
      nil
    end

    def clean_value(value)
      return nil if value.is_a?(Hash) || value.is_a?(Array)

      cleaned = value.to_s.gsub(/\s+/, " ").strip
      cleaned = cleaned.gsub(/\A[,\s]+|[,\s]+\z/, "")
      return nil if cleaned.blank?
      return nil if cleaned.match?(/\Ahttps?:\/\//i) || cleaned.include?("@")

      cleaned.truncate(255)
    end

    def normalize_field_name(value)
      value.to_s.downcase.gsub(/[^a-z0-9]+/, "_").gsub(/\A_+|_+\z/, "")
    end

    def normalize_key(value)
      value.to_s.downcase.gsub(/[^a-z0-9]+/, " ").squish.presence
    end

    def format_address(address1:, address2:, city:, state:, postal_code:, country:)
      locality = [city, state, postal_code].compact_blank.join(", ")
      [
        [address1, address2].compact_blank.join(" "),
        locality.presence,
        country
      ].compact_blank.join(" | ").gsub(/,\s*,+/, ",")
    end

    def source_path(path, raw_components)
      component_keys = raw_components.keys.map(&:to_s).sort.join("+")
      [path.join("."), component_keys].compact_blank.join("#")
    end

    def source_label(raw_components)
      raw_components.keys.filter_map do |key|
        label_map[key.to_s].presence || label_map[key.to_sym].presence
      end.first
    end

    def skipped_path?(path)
      path.any? { |part| SKIPPED_PATH_PARTS.include?(part.to_s) }
    end

    def free_text_path?(path)
      normalized_last = normalize_field_name(path.last)
      FREE_TEXT_KEYS.include?(normalized_last)
    end
  end
end
