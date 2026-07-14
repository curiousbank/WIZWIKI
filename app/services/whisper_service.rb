require "open3"
require "timeout"

module WhisperService
  DEFAULT_WHISPER_PATH = "whisper"
  DEFAULT_TIMEOUT_SECONDS = 45
  ALLOWED_WHISPER_PATHS = [ DEFAULT_WHISPER_PATH ].freeze

  def self.transcribe(tempfile_path)
    output_dir = File.dirname(tempfile_path)
    cmd = [
      whisper_path,
      tempfile_path.to_s,
      "--model", ENV.fetch("WHISPER_MODEL", "base"),
      "--fp16", "False",
      "--output_format", "txt",
      "--output_dir", output_dir.to_s
    ]

    stdout, stderr, status = capture_with_timeout(cmd, timeout_seconds)
    unless status.success?
      Rails.logger.error("[WIZWIKI Whisper] #{stderr.presence || stdout}")
      raise "Whisper failed with code #{status.exitstatus}"
    end

    txt_file = tempfile_path.sub(/\.\w+\z/, ".txt")
    raise "Whisper output file missing" unless File.exist?(txt_file)

    File.read(txt_file, encoding: "UTF-8").scrub.delete("\u0000").strip
  end

  def self.whisper_path
    candidate = ENV.fetch("WHISPER_PATH", DEFAULT_WHISPER_PATH).to_s
    return candidate if ALLOWED_WHISPER_PATHS.include?(candidate)

    raise "WHISPER_PATH is not allowlisted"
  end

  def self.timeout_seconds
    Integer(ENV.fetch("WHISPER_TIMEOUT_SECONDS", DEFAULT_TIMEOUT_SECONDS)).clamp(5, 180)
  rescue ArgumentError
    DEFAULT_TIMEOUT_SECONDS
  end

  def self.capture_with_timeout(cmd, timeout)
    Open3.popen3(*cmd) do |stdin, stdout, stderr, wait_thread|
      stdin.close
      stdout_reader = Thread.new { stdout.read.to_s }
      stderr_reader = Thread.new { stderr.read.to_s }

      unless wait_thread.join(timeout)
        terminate_process(wait_thread.pid)
        raise Timeout::Error, "Whisper timed out after #{timeout}s"
      end

      [stdout_reader.value, stderr_reader.value, wait_thread.value]
    end
  end

  def self.terminate_process(pid)
    Process.kill("TERM", pid)
    sleep 0.5
    Process.kill("KILL", pid)
  rescue Errno::ESRCH
    nil
  end
end
