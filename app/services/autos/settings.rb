module Autos
  module Settings
    DEFAULT_ALICE_VOICE = "alice-pro".freeze
    DEFAULT_TTS_MAX_SPOKEN_CHARS = 420
    DEFAULT_MAX_ANSWER_CHARS = 420
    DEFAULT_MAX_ANSWER_LINES = 4
    DEFAULT_TTS_TTL_SECONDS = 900
    DEFAULT_COQUI_TTS_PATH = "tts".freeze

    FRANKENSTEIN = <<~TEXT.squish
      Speak as Thumper von AUTOS. Use Sample Operator's Fathom-derived voice and the WIZWIKI Copy Playbook as paramount style memory: practical, direct, owner-operated, candid, and grounded in the customer's situation. Answer first, use real numbers when available, name one clear next step, and ask at most one low-friction question. Be warm, thoughtful, and thorough without sounding demanding. Do the useful work in the answer instead of describing what you are able to do. No corporate words, no habitual "Yep", no premature goodbye, no filler, and no repeated phrases. Safety and accuracy beat style.
    TEXT

    AUTOS_ROBOT_VOICES = %w[
      autos cg hal-1000 p330-deep detroit-current southside-signal rosewood-relay
      autos-arc-robot autos-deep-robot autos-deep-fast autos-electric chubs
    ].freeze
    TTS_MODELS = {
      "autos" => "tts_models/en/vctk/vits",
      "alice" => "tts_models/en/vctk/vits",
      "alice-pro" => "tts_models/en/vctk/vits",
      "cg" => "tts_models/multilingual/multi-dataset/xtts_v2",
      "hal-1000" => "tts_models/multilingual/multi-dataset/xtts_v2",
      "doughboy" => "tts_models/en/vctk/vits",
      "victor" => "tts_models/en/vctk/vits",
      "p227-clean" => "tts_models/en/vctk/vits",
      "p234-clean" => "tts_models/en/vctk/vits",
      "p236-clean" => "tts_models/en/vctk/vits",
      "p246-clean" => "tts_models/en/vctk/vits",
      "p270-clean" => "tts_models/en/vctk/vits",
      "p330-clean" => "tts_models/en/vctk/vits",
      "p330-deep" => "tts_models/en/vctk/vits",
      "detroit-current" => "tts_models/multilingual/multi-dataset/xtts_v2",
      "southside-signal" => "tts_models/multilingual/multi-dataset/xtts_v2",
      "rosewood-relay" => "tts_models/multilingual/multi-dataset/xtts_v2",
      "robot-overflow" => "tts_models/en/ljspeech/overflow",
      "autos-arc-robot" => "tts_models/en/ljspeech/overflow",
      "autos-deep-robot" => "tts_models/en/ljspeech/overflow",
      "autos-deep-fast" => "tts_models/en/ljspeech/overflow",
      "autos-electric" => "tts_models/en/ljspeech/overflow",
      "chubs" => "tts_models/en/ljspeech/overflow",
      "whisper-neural_hmm" => "tts_models/en/ljspeech/neural_hmm",
      "horror-capacitron" => "tts_models/en/blizzard2013/capacitron-t2-c150_v2",
      "spanish-male" => "tts_models/es/css10/vits"
    }.freeze
    TTS_SPEAKERS = {
      "autos" => "p251",
      "alice" => "p304",
      "alice-pro" => "p304",
      "cg" => "Damien Black",
      "hal-1000" => "Xavier Hayasaka",
      "doughboy" => "p234",
      "victor" => "p251",
      "p227-clean" => "p227",
      "p234-clean" => "p234",
      "p236-clean" => "p236",
      "p246-clean" => "p246",
      "p270-clean" => "p270",
      "p330-clean" => "p330",
      "p330-deep" => "p330",
      "detroit-current" => "Badr Odhiambo",
      "southside-signal" => "Ige Behringer",
      "rosewood-relay" => "Rosemary Okafor"
    }.freeze
    TTS_LANGUAGES = {
      "cg" => "en",
      "hal-1000" => "en",
      "detroit-current" => "en",
      "southside-signal" => "en",
      "rosewood-relay" => "en"
    }.freeze
    DEFAULT_TTS_MODEL = TTS_MODELS.fetch(DEFAULT_ALICE_VOICE).freeze
    SELECTABLE_TTS_VOICES = %w[
      autos alice alice-pro cg hal-1000 doughboy victor p270-clean p330-deep
    ].freeze
    TTS_VOICE_OPTIONS = [
      ["AUTOS", "autos"],
      ["ALICE", "alice"],
      ["ALICE PRO", "alice-pro"],
      ["CG", "cg"],
      ["HAL 1000", "hal-1000"],
      ["DOUGHBOY", "doughboy"],
      ["VICTOR", "victor"],
      ["THUMPER", "p270-clean"],
      ["CMAIL SNAIL", "p330-deep"]
    ].freeze

    AUTOS_ROBOT_FILTERS = {
      "autos" => "asetrate=22050*0.70,aresample=22050,atempo=0.98,highpass=f=75,lowpass=f=7600,equalizer=f=155:width_type=h:width=120:g=4,equalizer=f=3200:width_type=h:width=900:g=3,flanger=delay=4:depth=5:regen=24:width=65:speed=0.46,acrusher=level_in=1:level_out=0.96:bits=12:mode=log,aecho=0.80:0.86:48:0.17,volume=1.18",
      "cg" => "asetrate=24000*0.82,aresample=24000,atempo=1.05,highpass=f=70,lowpass=f=7900,equalizer=f=180:width_type=h:width=140:g=3,equalizer=f=3600:width_type=h:width=900:g=2.5,acrusher=level_in=1:level_out=0.98:bits=13:mode=log,aecho=0.82:0.88:36:0.15,flanger=delay=3:depth=4:regen=18:width=58:speed=0.55,volume=1.36",
      "hal-1000" => "asetrate=24000*0.76,aresample=24000,atempo=1.02,highpass=f=65,lowpass=f=7200,equalizer=f=140:width_type=h:width=130:g=4,aphaser=in_gain=0.72:out_gain=0.82:delay=3:decay=0.42:speed=0.42,aecho=0.80:0.90:82:0.24,volume=1.20",
      "p330-deep" => "asetrate=22050*0.74,aresample=22050,atempo=1.04,highpass=f=70,lowpass=f=7600,equalizer=f=165:width_type=h:width=120:g=3.5,equalizer=f=3300:width_type=h:width=900:g=2.5,flanger=delay=4:depth=5:regen=22:width=62:speed=0.44,acrusher=level_in=1:level_out=0.95:bits=12:mode=log,aecho=0.78:0.84:44:0.16,volume=1.16",
      "detroit-current" => "asetrate=24000*0.84,aresample=24000,atempo=1.04,highpass=f=72,lowpass=f=7800,equalizer=f=190:width_type=h:width=150:g=3,equalizer=f=2900:width_type=h:width=1000:g=2.3,aecho=0.78:0.84:38:0.13,flanger=delay=2.6:depth=3:regen=14:width=52:speed=0.48,volume=1.22",
      "southside-signal" => "asetrate=24000*0.88,aresample=24000,atempo=1.08,highpass=f=82,lowpass=f=8200,equalizer=f=240:width_type=h:width=180:g=2,equalizer=f=4100:width_type=h:width=1000:g=3.2,acrusher=level_in=1:level_out=0.98:bits=14:mode=log,aecho=0.76:0.82:30:0.10,volume=1.18",
      "rosewood-relay" => "asetrate=24000*0.90,aresample=24000,atempo=1.02,highpass=f=88,lowpass=f=8200,equalizer=f=220:width_type=h:width=180:g=2.5,equalizer=f=3400:width_type=h:width=1100:g=2.6,aecho=0.78:0.84:46:0.12,chorus=0.50:0.80:40:0.24:0.20:1.6,volume=1.16",
      "autos-arc-robot" => "asetrate=22050*0.64,aresample=22050,atempo=1.16,acrusher=level_in=1:level_out=0.92:bits=8:mode=log,aecho=0.8:0.92:58:0.20,chorus=0.55:0.9:50:0.35:0.25:2,tremolo=f=9:d=0.18,volume=1.15",
      "autos-deep-robot" => "asetrate=22050*0.58,aresample=22050,atempo=1.10,aecho=0.8:0.90:70:0.28,aphaser=in_gain=0.7:out_gain=0.8:delay=3:decay=0.5:speed=0.6,volume=1.12",
      "autos-deep-fast" => "asetrate=22050*0.80,aresample=22050,atempo=1.35,aecho=0.8:0.88:22:0.10,flanger=delay=3:depth=3:regen=20:width=60:speed=0.8,volume=1.08",
      "autos-electric" => "asetrate=22050*0.70,aresample=22050,atempo=1.22,acrusher=level_in=1:level_out=0.94:bits=10:mode=log,aecho=0.78:0.88:34:0.16,tremolo=f=12:d=0.12,volume=1.12",
      "chubs" => "asetrate=22050*0.50,aresample=22050,atempo=1.0,aecho=0.8:0.88:92:0.34,tremolo=f=4:d=0.08,volume=1.18",
      "default" => "asetrate=22050*0.64,aresample=22050,atempo=1.16,acrusher=level_in=1:level_out=0.92:bits=8:mode=log,aecho=0.8:0.92:58:0.20,chorus=0.55:0.9:50:0.35:0.25:2,tremolo=f=9:d=0.18,volume=1.15"
    }.freeze

    def self.alice_voice
      normalize_tts_voice(ENV.fetch("WIZWIKI_AUTOS_TTS_VOICE", ENV.fetch("AUTOS_TTS_VOICE", DEFAULT_ALICE_VOICE)).to_s.strip.presence || DEFAULT_ALICE_VOICE)
    end

    def self.max_answer_chars
      ENV.fetch("WIZWIKI_AUTOS_MAX_ANSWER_CHARS", DEFAULT_MAX_ANSWER_CHARS).to_i.clamp(180, 1_200)
    end

    def self.max_answer_lines
      ENV.fetch("WIZWIKI_AUTOS_MAX_ANSWER_LINES", DEFAULT_MAX_ANSWER_LINES).to_i.clamp(1, 8)
    end

    def self.tts_max_spoken_chars
      ENV.fetch("WIZWIKI_AUTOS_TTS_MAX_SPOKEN_CHARS", DEFAULT_TTS_MAX_SPOKEN_CHARS).to_i.clamp(180, 900)
    end

    def self.tts_ttl_seconds
      ENV.fetch("WIZWIKI_AUTOS_TTS_TTL_SECONDS", DEFAULT_TTS_TTL_SECONDS).to_i.clamp(60, 3_600)
    end

    def self.coqui_tts_path
      ENV.fetch("COQUI_TTS_PATH", DEFAULT_COQUI_TTS_PATH).to_s.strip.presence || DEFAULT_COQUI_TTS_PATH
    end

    def self.autos_robot_voice?(voice)
      AUTOS_ROBOT_VOICES.include?(voice.to_s)
    end

    def self.autos_robot_filter_for(voice)
      AUTOS_ROBOT_FILTERS.fetch(voice.to_s, AUTOS_ROBOT_FILTERS.fetch("default"))
    end

    def self.tts_voice_options
      TTS_VOICE_OPTIONS
    end

    def self.valid_tts_voice?(voice)
      SELECTABLE_TTS_VOICES.include?(voice.to_s)
    end

    def self.normalize_tts_voice(voice)
      voice = voice.to_s.strip
      valid_tts_voice?(voice) ? voice : DEFAULT_ALICE_VOICE
    end

    def self.tts_model_for(voice)
      TTS_MODELS.fetch(voice.to_s, DEFAULT_TTS_MODEL)
    end

    def self.tts_speaker_for(voice)
      TTS_SPEAKERS[voice.to_s]
    end

    def self.tts_language_for(voice)
      TTS_LANGUAGES[voice.to_s]
    end
  end
end
