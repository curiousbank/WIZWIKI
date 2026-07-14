# frozen_string_literal: true

module Comms
  class RagProfile
    SETTINGS_KEY = "comms_rag_profiles"
    DEFAULT_KEY = "wizwiki"
    LEGACY_KEY = DEFAULT_KEY
    PROFILE_KINDS = %w[support sales].freeze
    KEY_PATTERN = /\A[a-z0-9][a-z0-9_]{1,62}[a-z0-9]\z/.freeze

    PROFILES = {
      DEFAULT_KEY => {
        "key" => DEFAULT_KEY,
        "label" => "WIZWIKI CRM",
        "scope" => "wizwiki",
        "kind" => "sales",
        "description" => "Organization-owned CRM and communications knowledge"
      }.freeze
    }.freeze

    class << self
      def normalize(value, fallback: DEFAULT_KEY, organization: nil)
        key = normalize_key(value)
        return key if profiles_for(organization).key?(key)

        fallback_key = normalize_key(fallback)
        profiles_for(organization).key?(fallback_key) ? fallback_key : DEFAULT_KEY
      end

      def fetch(value, fallback: DEFAULT_KEY, organization: nil)
        profiles_for(organization).fetch(normalize(value, fallback: fallback, organization: organization))
      end

      def for_stage(stage, fallback: DEFAULT_KEY)
        metadata = stage&.metadata.to_h
        organization = stage&.organization || stage&.crm_record&.organization
        key = normalize_key(metadata["rag_profile"])
        return profiles_for(organization).fetch(key) if profiles_for(organization).key?(key)

        pinned = pinned_profile(metadata)
        return pinned if pinned.present?

        fetch(key, fallback: fallback, organization: organization)
      end

      def options(organization: nil)
        profiles_for(organization).values.map { |profile| [profile.fetch("label"), profile.fetch("key")] }
      end

      def support?(stage_or_key, organization: nil)
        profile = stage_or_key.respond_to?(:metadata) ? for_stage(stage_or_key) : fetch(stage_or_key, organization: organization)
        profile.fetch("kind") == "support"
      end

      def metadata_for(value, at: Time.current, user: nil, organization: nil)
        profile = fetch(value, organization: organization)
        {
          "rag_profile" => profile.fetch("key"),
          "rag_profile_label" => profile.fetch("label"),
          "rag_scope" => profile.fetch("scope"),
          "rag_kind" => profile.fetch("kind"),
          "rag_profile_saved_at" => at.iso8601,
          "rag_profile_saved_by_user_id" => user&.id,
          "rag_profile_saved_by" => user&.try(:display_name)
        }.compact_blank
      end

      def profiles_for(organization = nil)
        custom = organization&.settings.to_h.fetch(SETTINGS_KEY, {}).to_h
        custom.each_with_object(PROFILES.deep_dup) do |(raw_key, raw_profile), profiles|
          profile = sanitize_profile(raw_profile.to_h.merge("key" => raw_key), strict: false)
          profiles[profile.fetch("key")] = profile if profile.present? && !PROFILES.key?(profile.fetch("key"))
        end
      end

      def register!(organization:, key:, label:, scope: nil, kind: "support", description: nil)
        raise ArgumentError, "organization required" if organization.blank?

        profile = sanitize_profile(
          { "key" => key, "label" => label, "scope" => scope, "kind" => kind, "description" => description },
          strict: true
        )
        return PROFILES.fetch(profile.fetch("key")) if PROFILES.key?(profile.fetch("key"))

        organization.with_lock do
          organization.reload
          settings = organization.settings.to_h.deep_dup
          profiles = settings.fetch(SETTINGS_KEY, {}).to_h.deep_dup
          profiles[profile.fetch("key")] = profile
          settings[SETTINGS_KEY] = profiles
          organization.update!(settings: settings)
        end
        profile
      end

      private

      def normalize_key(value)
        value.to_s.strip.downcase.tr(".-", "_").gsub(/[^a-z0-9_]/, "_").gsub(/_+/, "_").sub(/\A_+/, "").sub(/_+\z/, "")
      end

      def sanitize_profile(raw, strict:)
        key = normalize_key(raw["key"])
        label = raw["label"].to_s.squish.first(80)
        scope = normalize_key(raw["scope"].presence || key)
        kind = raw["kind"].to_s.downcase.presence || "support"
        description = raw["description"].to_s.squish.first(240).presence
        errors = []
        errors << "key must be 3-64 lowercase letters, numbers, or underscores" unless key.match?(KEY_PATTERN)
        errors << "label required" if label.blank?
        errors << "scope must be 3-64 lowercase letters, numbers, or underscores" unless scope.match?(KEY_PATTERN)
        errors << "kind must be support or sales" unless PROFILE_KINDS.include?(kind)
        raise ArgumentError, errors.join("; ") if strict && errors.any?
        return if errors.any?

        { "key" => key, "label" => label, "scope" => scope, "kind" => kind, "description" => description }.compact_blank
      end

      def pinned_profile(metadata)
        key = normalize_key(metadata["rag_profile"])
        return if key.blank? || metadata["rag_profile_label"].blank? || metadata["rag_scope"].blank?

        sanitize_profile(
          {
            "key" => key,
            "label" => metadata["rag_profile_label"],
            "scope" => metadata["rag_scope"],
            "kind" => metadata["rag_kind"].presence || "support"
          },
          strict: false
        )
      end
    end
  end
end
