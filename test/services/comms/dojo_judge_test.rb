require "test_helper"

module Comms
  class DojoJudgeTest < ActiveSupport::TestCase
    test "judge provider cannot select OpenAI" do
      old_provider = ENV["WIZWIKI_DOJO_JUDGE_PROVIDER"]
      ENV["WIZWIKI_DOJO_JUDGE_PROVIDER"] = "openai"

      judge = DojoJudge.new(
        stage: nil,
        inbound: "How much for yard signs?",
        answer: "The Yard Signs package starts at $99 for 10 signs. Do you want signs-only?",
        draft_result: {},
        fallback_grade: {}
      )

      assert_equal "qwen_30b", judge.send(:judge_provider)
      refute_includes DojoJudge.private_instance_methods, :openai_grade
    ensure
      ENV["WIZWIKI_DOJO_JUDGE_PROVIDER"] = old_provider
    end
  end
end
