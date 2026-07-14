ENV["RAILS_ENV"] ||= "test"
ENV["WIZWIKI_SITE_PASSWORD"] ||= "test-gate"
require_relative "../config/environment"
ActiveRecord.maintain_test_schema = false if ENV["WEATHER_ISOLATED_TEST_SCHEMA"] == "true"
require "rails/test_help"
require_relative "test_helpers/session_test_helper"

module ActiveSupport
  class TestCase
    # Run tests in parallel with specified workers
    parallel_workers = ENV["PARALLEL_WORKERS"].present? ? ENV["PARALLEL_WORKERS"].to_i : (ENV["CI"].present? ? :number_of_processors : 1)
    parallelize(workers: parallel_workers)

    # Setup all fixtures in test/fixtures/*.yml for all tests in alphabetical order.
    fixtures :all

    # Add more helper methods to be used by all tests here...
  end
end

class ActionDispatch::IntegrationTest
  setup :unlock_site_gate

  private

  def unlock_site_gate
    post site_gate_path, params: { password: ENV.fetch("WIZWIKI_SITE_PASSWORD") }
  end
end
