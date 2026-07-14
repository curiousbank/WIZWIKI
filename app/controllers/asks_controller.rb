class AsksController < ApplicationController
  before_action :require_organization!
  helper_method :ask_sms_writer_model_options

  def index
    warm_thumper_context_cache_later!("ask")
    @autos_question = AutosQuestion.new
    @recent_questions = chat_questions
    load_autopilot_test
    @ask_sms_writer_model = ask_sms_writer_model_param(@ask_autopilot_test)
  end

  def questions
    @recent_questions = chat_questions
    load_autopilot_test
    @ask_sms_writer_model = ask_sms_writer_model_param(@ask_autopilot_test)

    respond_to do |format|
      format.turbo_stream
      format.html { redirect_to ask_path }
    end
  end

  def show_autopilot_test
    @autos_question = AutosQuestion.new
    load_autopilot_test
    remember_autopilot_test(@ask_autopilot_test)
    @ask_sms_writer_model = ask_sms_writer_model_param(@ask_autopilot_test)

    if params[:version].present? && !truthy_param?(params[:force]) && @ask_autopilot_test.to_h["version"].to_s == params[:version].to_s
      return head :no_content
    end

    respond_to_autopilot_test
  end

  def create
    load_autopilot_test
    @ask_sms_writer_model = ask_sms_writer_model_param(@ask_autopilot_test)
    remember_ask_sms_writer_model!(@ask_sms_writer_model)
    prompt_text = ask_prompt_text
    @autos_question = current_organization.autos_questions.new(
      question: prompt_text,
      context: autos_question_context,
      metadata: autos_metadata
    )
    @autos_question.user = current_user
    @autos_question.status = "queued"

    if @autos_question.save
      if ask_sms_writer_cloud_model?(@ask_sms_writer_model) && defined?(Autos::CloudAnswerer)
        Autos::CloudAnswerer.queue!(@autos_question)
      elsif Autos::WorkerQueue.enabled_for?(@autos_question)
        Autos::WorkerQueue.queue!(@autos_question)
      else
        Autos::OpenaiAnswerer.call(@autos_question)
        mark_voice_queued!(@autos_question) if @autos_question.reload.answer.present?
      end
      @recent_questions = chat_questions

      respond_to do |format|
        format.turbo_stream
        format.html { redirect_to ask_path, notice: "THUMPER is answering." }
      end
    else
      @recent_questions = chat_questions
      flash.now[:alert] = @autos_question.errors.full_messages.to_sentence
      render :index, status: :unprocessable_entity
    end
  rescue StandardError => error
    Rails.logger.warn("[WIZWIKI Ask] #{error.class}: #{error.message}")
    @autos_question ||= AutosQuestion.new(question: params.dig(:autos_question, :question).to_s, context: autos_question_context)
    @recent_questions = chat_questions
    flash.now[:alert] = "THUMPER ask path sparked: #{error.message.to_s.truncate(160)}"
    render :index, status: :unprocessable_entity
  end

  def start_autopilot_test
    @autos_question = AutosQuestion.new
    @recent_questions = chat_questions
    @ask_sms_writer_model = ask_sms_writer_model_param
    remember_ask_sms_writer_model!(@ask_sms_writer_model)
    @ask_autopilot_test = Comms::AskAutopilotTest.start(
      user: current_user,
      organization: current_organization,
      writer_model: @ask_sms_writer_model
    )
    remember_autopilot_test(@ask_autopilot_test)

    respond_to_autopilot_test("SMS autopilot test started.")
  end

  def reply_autopilot_test
    warm_thumper_context_cache_later!("ask")
    @autos_question = AutosQuestion.new
    @recent_questions = chat_questions
    @ask_sms_writer_model = ask_sms_writer_model_param(@ask_autopilot_test)
    remember_ask_sms_writer_model!(@ask_sms_writer_model)
    @ask_autopilot_test = Comms::AskAutopilotTest.reply(
      session[:ask_autopilot_test],
      text: params.dig(:ask_autopilot_test, :message).presence || params[:message],
      user: current_user,
      organization: current_organization,
      writer_model: @ask_sms_writer_model,
      async: true
    )
    remember_autopilot_test(@ask_autopilot_test)

    respond_to_autopilot_test
  end

  def start_recursive_dojo
    warm_thumper_context_cache_later!("ask")
    @autos_question = AutosQuestion.new
    @recent_questions = chat_questions
    @ask_sms_writer_model = ask_sms_writer_model_param(@ask_autopilot_test)
    remember_ask_sms_writer_model!(@ask_sms_writer_model)
    @ask_autopilot_test = Comms::AskAutopilotTest.start_recursive_dojo(
      session[:ask_autopilot_test],
      guidance: params.dig(:ask_autopilot_test, :message).presence || params[:message],
      user: current_user,
      organization: current_organization,
      writer_model: @ask_sms_writer_model,
      async: true
    )
    remember_autopilot_test(@ask_autopilot_test)

    respond_to_autopilot_test
  end

  def clear_autopilot_test
    Comms::AskAutopilotTest.clear(session[:ask_autopilot_test], organization: current_organization)
    session.delete(:ask_autopilot_test)
    @autos_question = AutosQuestion.new
    @recent_questions = chat_questions
    @ask_autopilot_test = nil
    @ask_sms_writer_model = ask_sms_writer_model_param

    respond_to_autopilot_test("SMS autopilot test cleared.")
  end

  private

  def warm_thumper_context_cache_later!(surface)
    Autos::ContextCache.warm_later(organization: current_organization, user: current_user, surface: surface) if defined?(Autos::ContextCache)
  end

  def chat_questions
    current_organization.autos_questions
      .where(user: current_user)
      .where("metadata ->> 'surface' IS NULL OR metadata ->> 'surface' = ?", "ask")
      .recent
      .limit(12)
  end

  def load_autopilot_test
    @ask_autopilot_test = Comms::AskAutopilotTest.load(
      session[:ask_autopilot_test],
      user: current_user,
      organization: current_organization
    )
    @ask_autopilot_test = nil unless active_autopilot_payload?(@ask_autopilot_test)
    @ask_autopilot_test ||= latest_active_autopilot_test
    remember_autopilot_test(@ask_autopilot_test)
  rescue StandardError => error
    Rails.logger.warn("[AskAutopilotTest] load failed user=#{current_user&.id} #{error.class}: #{error.message}")
    session.delete(:ask_autopilot_test)
    @ask_autopilot_test = nil
  end

  def latest_active_autopilot_test
    return if current_user.blank? || current_organization.blank?

    stage = current_organization.crm_record_artifacts
      .where(user_id: current_user.id, artifact_type: "comm_staging")
      .where("metadata ->> 'stage_type' = ?", "ask_autopilot_test")
      .where("metadata ->> 'ask_autopilot_test_active' = ?", "true")
      .order(updated_at: :desc)
      .first
    return if stage.blank?

    Comms::AskAutopilotTest.load(
      { "stage_id" => stage.id },
      user: current_user,
      organization: current_organization
    )
  end

  def remember_autopilot_test(payload)
    stage_id = payload.to_h["stage_id"].presence
    if stage_id.present? && active_autopilot_payload?(payload)
      session[:ask_autopilot_test] = { "stage_id" => stage_id }
    else
      session.delete(:ask_autopilot_test)
    end
  end

  def active_autopilot_payload?(payload)
    payload.present? && Comms::AskAutopilotTest.active?(payload)
  end

  def ask_sms_writer_model_options
    WizwikiSettings.sms_writer_model_options
  end

  def ask_sms_writer_model_param(payload = nil)
    payload_model = payload.present? ? WizwikiSettings.sms_writer_model_from_metadata(payload) : nil
    session_model = session[:ask_sms_writer_model].presence
    if WizwikiSettings.stale_default_sms_writer_model?(session_model, preferred_model: payload_model)
      session_model = nil
    end

    WizwikiSettings.sms_writer_model_from_request(
      params.dig(:autos_question, :sms_writer_model).presence ||
        params.dig(:ask_autopilot_test, :sms_writer_model).presence ||
        params[:sms_writer_model].presence,
      fallback: payload_model || session_model || WizwikiSettings.default_sms_writer_model
    )
  end

  def remember_ask_sms_writer_model!(model)
    session[:ask_sms_writer_model] = WizwikiSettings.normalize_sms_writer_model(model)
  end

  def ask_sms_writer_cloud_model?(model)
    WizwikiSettings.sms_writer_cloud_provider(model).present?
  end

  def respond_to_autopilot_test(notice_message = nil)
    respond_to do |format|
      format.turbo_stream { render :autopilot_test }
      format.html { redirect_to ask_path(anchor: "ask-autopilot-test"), notice: notice_message }
    end
  end

  def ask_prompt_text
    text = params.dig(:autos_question, :question).to_s.strip
    return text if text.present?

    transcribe_voice_blob.presence || text
  end

  def autos_question_context
    params.dig(:autos_question, :context).to_s.strip
  end

  def autos_metadata
    input_mode = params[:voice_blob].present? && params.dig(:autos_question, :question).to_s.strip.blank? ? "voice" : "text"
    writer_model = @ask_sms_writer_model.presence || ask_sms_writer_model_param(@ask_autopilot_test)
    {
      "input_mode" => input_mode,
      "full_talk" => truthy_param?(params[:full_talk]),
      "autos_voice_preference" => selected_autos_voice,
      "writer_model" => writer_model,
      "writer_model_label" => WizwikiSettings.sms_writer_model_label(writer_model),
      "sms_writer_model" => writer_model,
      "sms_writer_model_label" => WizwikiSettings.sms_writer_model_label(writer_model),
      "surface" => "ask",
      "submitted_at" => Time.current.iso8601
    }
  end

  def selected_autos_voice
    Autos::Settings.normalize_tts_voice(
      params.dig(:autos_question, :autos_voice).presence || params[:autos_voice].presence || params[:autos_tts_voice].presence
    )
  end

  def transcribe_voice_blob
    return "" unless params[:voice_blob].present?

    uploaded = params[:voice_blob]
    Tempfile.create(["wizwiki_thumper_voice", ".webm"], binmode: true) do |file|
      file.write(uploaded.read)
      file.flush
      WhisperService.transcribe(file.path).to_s.strip
    end
  end

  def truthy_param?(value)
    %w[1 true yes on].include?(value.to_s.downcase)
  end

  def mark_voice_queued!(question)
    metadata = question.metadata.to_h.deep_dup
    metadata["autos_voice_status"] = "queued"
    question.update!(metadata: metadata)
    Autos::VoiceJob.perform_later(question.id)
  end
end
