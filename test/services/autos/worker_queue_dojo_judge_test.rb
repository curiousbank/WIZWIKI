require "test_helper"

module Autos
  class WorkerQueueDojoJudgeTest < ActiveSupport::TestCase
    FakeQuestion = Struct.new(:id, :organization_id, :user_id, :question, :context, :metadata, keyword_init: true) do
      def update!(attributes)
        self.metadata = attributes.fetch(:metadata)
      end
    end

    test "dojo judge work is priority and local only" do
      assert_includes WorkerQueue::PRIORITY_SURFACES, "dojo_judge"

      question = FakeQuestion.new(
        id: 123,
        organization_id: 1,
        user_id: 2,
        question: "{\"score\":90}",
        context: "Recursive Dojo judge job.",
        metadata: {
          "surface" => "dojo_judge",
          "local_worker" => { "provider" => "qwen/local" }
        }
      )

      payload = WorkerQueue.payload_for(question)

      assert_equal "dojo_judge", payload[:surface]
      assert_equal false, payload.dig(:openai, :enabled)
      assert_equal false, payload.dig(:openai, :fallback_allowed)
      assert_match(/Recursive Dojo/, payload[:system_prompt])
    end
  end
end
