# frozen_string_literal: true

module Comms
  class AskAutopilotReplyJob < ApplicationJob
    queue_as :default

    def perform(stage_id:, inbound_event_id:, user_id:, generation: nil)
      Comms::AskAutopilotTest.process_reply(
        stage_id: stage_id,
        inbound_event_id: inbound_event_id,
        user_id: user_id,
        generation: generation
      )
    end
  end
end
