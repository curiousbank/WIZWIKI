require "fileutils"

class TtsService
  def self.generate_url(text:, voice:, ttl: 15.minutes)
    return nil if text.to_s.strip.blank?

    voice = voice.to_s.presence || Autos::Settings.alice_voice
    output_filename = "generated_#{SecureRandom.hex(8)}.wav"
    raw_output_filename = "raw_#{output_filename}"
    output_dir = Rails.root.join("public", "tts")
    output_path = output_dir.join(output_filename)
    raw_output_path = output_dir.join(raw_output_filename)
    numba_cache_dir = Rails.root.join("tmp", "numba_cache")
    FileUtils.mkdir_p(output_dir)
    FileUtils.mkdir_p(numba_cache_dir)

    model_name, speaker_idx, language_idx = model_for(voice)
    env = { "NUMBA_CACHE_DIR" => numba_cache_dir.to_s }
    target_path = autos_robot_voice?(voice) ? raw_output_path : output_path
    cmd = [
      Autos::Settings.coqui_tts_path,
      "--text", text.to_s,
      "--model_name", model_name,
      "--out_path", target_path.to_s
    ]
    cmd.concat(["--speaker_idx", speaker_idx.to_s]) if speaker_idx.present?
    cmd.concat(["--language_idx", language_idx.to_s]) if language_idx.present?

    Rails.logger.info("[WIZWIKI TTS] Running #{cmd.first} voice=#{voice}")
    system(env, *cmd)

    return nil unless File.exist?(target_path)

    if autos_robot_voice?(voice)
      unless post_process_autos_robot_voice(raw_output_path, output_path, voice)
        Rails.logger.warn("[WIZWIKI TTS] Robot post-process unavailable; using raw output")
        FileUtils.mv(raw_output_path, output_path)
      end
      File.delete(raw_output_path) if raw_output_path != output_path && File.exist?(raw_output_path)
    end

    Thread.new do
      sleep ttl.to_i
      File.delete(output_path) if File.exist?(output_path)
    end

    "/tts/#{output_filename}"
  rescue StandardError => error
    Rails.logger.warn("[WIZWIKI TTS] #{error.class}: #{error.message}")
    nil
  end

  def self.autos_robot_voice?(voice)
    Autos::Settings.autos_robot_voice?(voice)
  end

  def self.ffmpeg_available?
    @ffmpeg_available = system("ffmpeg", "-version", out: File::NULL, err: File::NULL) if @ffmpeg_available.nil?
    @ffmpeg_available
  end

  def self.post_process_autos_robot_voice(raw_output_path, output_path, voice = Autos::Settings::DEFAULT_ALICE_VOICE)
    return false unless ffmpeg_available?

    system(
      "ffmpeg", "-y", "-loglevel", "error",
      "-i", raw_output_path.to_s,
      "-filter:a", autos_robot_filter_for(voice),
      output_path.to_s
    )
    size = File.size?(output_path)
    File.exist?(output_path) && size && size.positive?
  rescue StandardError => error
    Rails.logger.warn("[WIZWIKI TTS] Robot post-process failed: #{error.class}: #{error.message}")
    false
  end

  def self.autos_robot_filter_for(voice)
    Autos::Settings.autos_robot_filter_for(voice)
  end

  def self.model_for(voice)
    [
      Autos::Settings.tts_model_for(voice),
      Autos::Settings.tts_speaker_for(voice),
      Autos::Settings.tts_language_for(voice)
    ]
  end
end
