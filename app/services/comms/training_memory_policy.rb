# frozen_string_literal: true

module Comms
  class TrainingMemoryPolicy
    VOICE_KINDS = %w[thumper_voice_canon copywriter_voice].freeze
    GUARDRAIL_KINDS = %w[
      comms_quality_memory
      comms_dojo_scorecard_memory
      thumper_recursive_autopilot_repair
      thumper_focused_sms_repair_eval
    ].freeze
    JUDGE_KINDS = %w[comms_dojo_judge_memory].freeze
    CURATED_EXAMPLE_KINDS = %w[
      thumper_preferred_sms_example
      thumper_recursive_eval
      thumper_recursive_autopilot_eval
      thumper_budget_language_yard_signs
      thumper_sms_rush_order_examples
    ].freeze
    BLOCKED_ROLES = %w[judge_calibration quarantined_memory negative_example].freeze
    ROLE_BOOSTS = {
      "voice_authority" => 140,
      "fact_authority" => 115,
      "procedural_skill" => 105,
      "guardrail" => 85,
      "curated_example" => 65,
      "positive_example" => 55,
      "training_reference" => 25,
      "judge_calibration" => -200,
      "quarantined_memory" => -300,
      "negative_example" => -300
    }.freeze

    class << self
      def role_for(source)
        metadata = source_metadata(source)
        kind = metadata["training_kind"].to_s
        return approved_positive_memory?(metadata) ? "positive_example" : "quarantined_memory" if kind == "comms_playbook_memory"

        explicit = metadata["retrieval_role"].to_s.presence
        return explicit if explicit.present?

        title = source_title(source).downcase
        resource_key = metadata["resource_key"].to_s

        return "voice_authority" if VOICE_KINDS.include?(kind)
        return canonical_resource_role(resource_key, metadata) if kind == "rag_canonical_resource"
        return "judge_calibration" if JUDGE_KINDS.include?(kind)
        return "guardrail" if GUARDRAIL_KINDS.include?(kind)
        return "curated_example" if CURATED_EXAMPLE_KINDS.include?(kind)
        return fine_training_role(title) if kind == "fine_training_document"

        "training_reference"
      end

      def composition_eligible?(source)
        metadata = source_metadata(source)
        return false if source_status(source) == "archived"
        return false if metadata["training_kind"].to_s == "comms_playbook_memory" && !approved_positive_memory?(metadata)
        return false if metadata["retrieval_priority"].to_s.match?(/archived|removed|quarantined|blocked/i)
        return false if metadata.key?("composition_eligible") && !truthy?(metadata["composition_eligible"])

        !BLOCKED_ROLES.include?(role_for(source))
      end

      def priority_boost(source)
        ROLE_BOOSTS.fetch(role_for(source), 0)
      end

      def usage_rule(source)
        case role_for(source)
        when "voice_authority"
          "Use as the governing Thumper/WIZWIKI voice. Follow it over older wording samples."
        when "fact_authority"
          "Use for current product, price, link, and process facts. Facts override examples."
        when "procedural_skill"
          "Apply the matching workflow on demand; do not copy it as customer text."
        when "guardrail"
          "Use as a correction checklist. Do not imitate rejected or diagnostic wording."
        when "curated_example", "positive_example"
          "Use the conversational pattern, not the exact wording or stale facts."
        when "judge_calibration"
          "Judge-only calibration. Never use as customer-facing composition memory."
        when "quarantined_memory", "negative_example"
          "Quarantined. Never use as customer-facing composition memory."
        else
          "Use only when relevant and subordinate it to voice and fact authorities."
        end
      end

      def embedding_metadata(source)
        metadata = source_metadata(source)
        {
          "training_kind" => metadata["training_kind"],
          "resource_key" => metadata["resource_key"],
          "category" => metadata["category"],
          "retrieval_priority" => metadata["retrieval_priority"],
          "training_priority" => metadata["training_priority"],
          "learning_status" => metadata["learning_status"],
          "human_reviewed" => metadata["human_reviewed"],
          "reviewed_at" => metadata["reviewed_at"],
          "retrieval_role" => role_for(source),
          "composition_eligible" => composition_eligible?(source),
          "usage_rule" => usage_rule(source)
        }.compact
      end

      def approved_positive_memory?(metadata)
        values = metadata.to_h.stringify_keys
        values["learning_status"].to_s == "approved_positive" && truthy?(values["human_reviewed"])
      end

      private

      def canonical_resource_role(resource_key, metadata)
        category = metadata["category"].to_s
        return "judge_calibration" if resource_key.include?("judge") || category.include?("judge")
        return "voice_authority" if resource_key.include?("thumper_vibe") || category.include?("vibe")
        return "fact_authority" if resource_key.include?("product") || category.include?("product")
        return "procedural_skill" if resource_key.include?("skills") || category.include?("skills")
        return "curated_example" if resource_key.include?("examples") || category.include?("examples")

        "guardrail"
      end

      def fine_training_role(title)
        return "voice_authority" if title.match?(/(?:codex_voice|voice_and_tone|copy playbook|thumper voice)/i)
        return "fact_authority" if title.match?(/(?:product_knowledge|product_and_process|active_promotions|business_profile)/i)
        return "curated_example" if title.match?(/(?:examples|message_patterns|customer_interaction|hermes_|sms_)/i)

        "training_reference"
      end

      def source_metadata(source)
        return source.to_h.stringify_keys if source.is_a?(Hash)

        source.respond_to?(:metadata) ? source.metadata.to_h.stringify_keys : {}
      end

      def source_title(source)
        return source.to_h[:title].to_s.presence || source.to_h["title"].to_s if source.is_a?(Hash)

        source.respond_to?(:title) ? source.title.to_s : ""
      end

      def source_status(source)
        return source.to_h[:status].to_s.presence || source.to_h["status"].to_s if source.is_a?(Hash)

        source.respond_to?(:status) ? source.status.to_s : ""
      end

      def truthy?(value)
        value == true || value.to_s == "true" || value.to_s == "1"
      end
    end
  end
end
