require "json"
require "open3"
require "timeout"

module Autos
  class MemoryBus
    STREAM = ENV.fetch("WIZWIKI_RORE_MEMORY_STREAM", "agent:events")
    RUN_STREAM_EVENTS = ENV.fetch("WIZWIKI_RORE_RUN_STREAM_EVENTS", ENV.fetch("AGENT_RUN_STREAM_EVENTS", "agent:runs:events"))
    RUN_STREAM_DEAD = ENV.fetch("WIZWIKI_RORE_RUN_STREAM_DEAD", ENV.fetch("AGENT_RUN_STREAM_DEAD", "agent:runs:dead"))
    RUN_MEMORY_PREFIX = ENV.fetch("WIZWIKI_RORE_RUN_MEMORY_PREFIX", ENV.fetch("AGENT_RUN_MEMORY_PREFIX", "agent:run"))
    RUN_MEMORY_TTL_SECONDS = ENV.fetch("WIZWIKI_RORE_RUN_MEMORY_TTL_SECONDS", ENV.fetch("AGENT_RUN_MEMORY_TTL_SECONDS", "604800")).to_i
    MAXLEN = ENV.fetch("WIZWIKI_RORE_STREAM_MAXLEN", "1000")
    REDIS_URL = ENV.fetch("WIZWIKI_RORE_REDIS_URL", "redis://127.0.0.1:6379/15")
    REDIS_CLI = ENV.fetch("WIZWIKI_RORE_REDIS_CLI", "redis-cli")

    class << self
      def publish(event, payload = {})
        message = {
          time: Time.zone.now.iso8601,
          event: event.to_s,
          source: "wizwiki",
          payload: payload.to_h
        }
        write_audit_log(message)
        publish_redis(message) if redis_enabled?
        message
      rescue StandardError => error
        Rails.logger.warn("[Autos::MemoryBus] publish failed event=#{event} #{error.class}: #{error.message}")
        nil
      end

      def run_id_for(source:, record_type:, record_id:)
        [
          "run",
          safe_token(source),
          safe_token(record_type),
          safe_token(record_id)
        ].join(":")
      end

      def record_run!(run_id:, event:, source:, record_type:, record_id:, status:, agent: nil, payload: {}, memory: {})
        message = {
          time: Time.zone.now.iso8601,
          event: event.to_s,
          source: source.to_s,
          run_id: run_id.to_s,
          record_type: record_type.to_s,
          record_id: record_id.to_s,
          status: status.to_s,
          agent: agent.to_s,
          payload: scrub_hash(payload.to_h)
        }
        write_audit_log(message)
        return message unless redis_enabled?

        merge_run_memory(run_id, {
          run_id: run_id,
          source: source,
          record: { type: record_type, id: record_id },
          status: status,
          agent: agent,
          updated_at: message.fetch(:time)
        }.merge(memory.to_h))
        publish_run_event(message)
        message
      rescue StandardError => error
        Rails.logger.warn("[Autos::MemoryBus] record_run failed event=#{event} #{error.class}: #{error.message}")
        nil
      end

      private

      def redis_enabled?
        ENV["WIZWIKI_RORE_ENABLED"].to_s.downcase.in?(%w[1 true yes on])
      end

      def write_audit_log(message)
        path = Rails.root.join("log/autos_memory_events.jsonl")
        File.open(path, "a") { |file| file.puts(JSON.generate(message)) }
      rescue StandardError => error
        Rails.logger.warn("[Autos::MemoryBus] audit log failed #{error.class}: #{error.message}")
      end

      def publish_redis(message)
        body = JSON.generate(message.fetch(:payload))
        fields = {
          "from" => "wizwiki",
          "to" => "alice",
          "type" => "memory_event",
          "priority" => "normal",
          "subject" => "WIZWIKI #{message.fetch(:event)}",
          "body" => body,
          "created_at" => message.fetch(:time),
          "requires_ack" => "false",
          "memory_event" => message.fetch(:event)
        }

        args = [REDIS_CLI, "-u", REDIS_URL, "XADD", STREAM, "MAXLEN", "~", MAXLEN, "*"]
        fields.each { |key, value| args.concat([key, value.to_s]) }

        Timeout.timeout(1.5) do
          _stdout, stderr, status = Open3.capture3(*args)
          Rails.logger.warn("[Autos::MemoryBus] redis publish failed: #{stderr.to_s.strip}") unless status.success?
        end
      rescue Timeout::Error
        Rails.logger.warn("[Autos::MemoryBus] redis publish timed out")
      rescue Errno::ENOENT
        Rails.logger.warn("[Autos::MemoryBus] redis-cli not found; audit log only")
      end

      def publish_run_event(message)
        fields = {
          "version" => "1",
          "protocol" => "rore.run.v1",
          "type" => message.fetch(:event),
          "run_id" => message.fetch(:run_id),
          "source" => message.fetch(:source),
          "record_type" => message.fetch(:record_type),
          "record_id" => message.fetch(:record_id),
          "status" => message.fetch(:status),
          "agent" => message.fetch(:agent),
          "payload" => JSON.generate(message.fetch(:payload)),
          "created_at" => message.fetch(:time)
        }
        redis_xadd(RUN_STREAM_EVENTS, fields)
      end

      def merge_run_memory(run_id, patch)
        key = "#{RUN_MEMORY_PREFIX}:#{safe_token(run_id)}:memory"
        current = redis_get_json(key)
        updated = deep_merge(current, scrub_hash(patch.to_h))
        args = [REDIS_CLI, "-u", REDIS_URL, "SETEX", key, RUN_MEMORY_TTL_SECONDS.to_s, JSON.generate(updated)]

        Timeout.timeout(1.5) do
          _stdout, stderr, status = Open3.capture3(*args)
          Rails.logger.warn("[Autos::MemoryBus] redis memory write failed: #{stderr.to_s.strip}") unless status.success?
        end
        updated
      rescue Timeout::Error
        Rails.logger.warn("[Autos::MemoryBus] redis memory write timed out")
        {}
      end

      def redis_get_json(key)
        stdout, _stderr, status = Open3.capture3(REDIS_CLI, "-u", REDIS_URL, "GET", key)
        return {} unless status.success? && stdout.present?

        JSON.parse(stdout)
      rescue JSON::ParserError
        {}
      end

      def redis_xadd(stream, fields)
        args = [REDIS_CLI, "-u", REDIS_URL, "XADD", stream, "MAXLEN", "~", MAXLEN, "*"]
        fields.each { |key, value| args.concat([key, value.to_s]) }

        Timeout.timeout(1.5) do
          _stdout, stderr, status = Open3.capture3(*args)
          Rails.logger.warn("[Autos::MemoryBus] redis run event failed: #{stderr.to_s.strip}") unless status.success?
        end
      rescue Timeout::Error
        Rails.logger.warn("[Autos::MemoryBus] redis run event timed out")
      end

      def deep_merge(left, right)
        left.to_h.merge(right.to_h) do |_key, old_value, new_value|
          old_value.is_a?(Hash) && new_value.is_a?(Hash) ? deep_merge(old_value, new_value) : new_value
        end
      end

      def scrub_hash(hash)
        hash.to_h.each_with_object({}) do |(key, value), memo|
          memo[key.to_s] = scrub_value(value)
        end
      end

      def scrub_value(value)
        case value
        when Hash
          scrub_hash(value)
        when Array
          value.map { |item| scrub_value(item) }
        when Time, ActiveSupport::TimeWithZone
          value.iso8601
        else
          return value if value.is_a?(Numeric) || value == true || value == false || value.nil?

          value.to_s
            .gsub(%r{(?:[A-Za-z0-9_.-]+:)?/(?:Users|home|Volumes|mnt|var|tmp)/[^\s"'<>),]+}, "[PRIVATE_PATH]")
            .gsub(%r{~/(?:Desktop|Documents|Downloads|Library|\.config)/[^\s"'<>),]+}, "[PRIVATE_PATH]")
            .gsub(/sk-[A-Za-z0-9_\-]{12,}/, "[OPENAI_KEY]")
            .truncate(2_000)
        end
      end

      def safe_token(value)
        value.to_s.downcase.strip
          .gsub(/[^a-z0-9_.:-]+/, "-")
          .gsub(/\A[-:.]+|[-:.]+\z/, "")
          .presence || "unknown"
      end
    end
  end
end
