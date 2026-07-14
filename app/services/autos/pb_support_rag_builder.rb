# frozen_string_literal: true

module Autos
  class PbSupportRagBuilder
    PROFILE_KEY = Comms::RagProfile::SUPPORT_KEY
    PROFILE_LABEL = "313.cash / Powderball"
    SCOPE = "313_cash"
    DEFAULT_PAGES = {
      "faq" => ENV.fetch("PB_RAG_FAQ_URL", "https://313.cash/faq"),
      "guide" => ENV.fetch("PB_RAG_GUIDE_URL", "https://313.cash/guide")
    }.freeze

    class << self
      def call(organization:, user:, pages: DEFAULT_PAGES, enqueue_embeddings: false)
        Autos::UrlRagBuilder.call(
          organization: organization,
          user: user,
          profile_key: PROFILE_KEY,
          profile_label: PROFILE_LABEL,
          profile_kind: "support",
          description: "313.cash onboarding, FAQ, airdrops, games, and Powderball support",
          pages: pages,
          enqueue_embeddings: enqueue_embeddings
        ).merge(scope: SCOPE)
      end
    end
  end
end
