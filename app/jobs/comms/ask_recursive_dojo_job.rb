# frozen_string_literal: true

module Comms
  class AskRecursiveDojoJob < ApplicationJob
    queue_as :default

    def perform(stage_id:, user_id:, guidance: nil, writer_model: nil, generation: nil)
      Comms::AskAutopilotTest.process_recursive_dojo(
        stage_id: stage_id,
        user_id: user_id,
        guidance: guidance,
        writer_model: writer_model,
        generation: generation
      )
    end
  end
end
