# frozen_string_literal: true

require "test_helper"
require "securerandom"

module Comms
  class RagProfileTest < ActiveSupport::TestCase
    setup do
      suffix = SecureRandom.hex(4)
      @organization = Organization.create!(name: "RAG profiles #{suffix}", slug: "rag-profiles-#{suffix}")
    end

    test "the public foundation has only the neutral WIZWIKI CRM built-in" do
      assert_equal "wizwiki", RagProfile.fetch(nil).fetch("key")
      assert_equal "sales", RagProfile.fetch("wizwiki").fetch("kind")
      assert_equal [["WIZWIKI CRM", "wizwiki"]], RagProfile.options
      assert_equal "wizwiki", RagProfile.fetch("unknown_private_profile").fetch("key")
    end

    test "an organization can register another unique selectable RAG" do
      profile = RagProfile.register!(
        organization: @organization,
        key: "Roofing FAQ",
        label: "Roofing FAQ",
        kind: "support",
        description: "Roofing onboarding answers"
      )

      assert_equal "roofing_faq", profile.fetch("key")
      assert_equal "roofing_faq", profile.fetch("scope")
      assert_includes RagProfile.options(organization: @organization), ["Roofing FAQ", "roofing_faq"]
      assert_equal profile, RagProfile.fetch("roofing_faq", organization: @organization)
    end

    test "new and untagged call blocks default to WIZWIKI CRM" do
      record = CrmRecord.create!(
        organization: @organization,
        name: "RAG profile test",
        record_type: "deal",
        fingerprint: "rag-profile-#{SecureRandom.hex(6)}"
      )
      stage = CrmRecordArtifact.create!(
        organization: @organization,
        crm_record: record,
        user: users(:one),
        artifact_type: "comm_staging",
        status: "staged",
        title: "RAG stage",
        metadata: {}
      )

      assert_equal "wizwiki", stage.metadata.fetch("rag_profile")
      stage.update_column(:metadata, {})
      assert_equal "wizwiki", RagProfile.for_stage(stage.reload).fetch("key")
    end
  end
end
