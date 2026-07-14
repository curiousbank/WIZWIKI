# frozen_string_literal: true

require "test_helper"

module Autos
  class WorkerQueueRagProfileTest < ActiveSupport::TestCase
    test "a comms question carries its selected retrieval scope" do
      assert_equal "member_manual", WorkerQueue.send(
        :retrieval_scope_for,
        "comms_sms_draft",
        { "rag_profile" => "member_manual", "rag_scope" => "member_manual" }
      )
      assert_equal "wizwiki", WorkerQueue.send(:retrieval_scope_for, "comms_sms_draft", { "rag_profile" => "wizwiki" })
      assert_equal "weather_calibration", WorkerQueue.send(:retrieval_scope_for, "weather_outcome_analysis", {})
    end
  end
end
