import { Controller } from "@hotwired/stimulus"
import { Turbo } from "@hotwired/turbo-rails"

export default class extends Controller {
  static targets = [
    "fullTalkInput",
    "fullTalkToggle",
    "fullTalkIcon",
    "fullTalkLabel",
    "voiceButton",
    "voiceIcon",
    "voiceLabel",
    "voiceStatus"
  ]

  static values = {
    askUrl: String
  }

  connect() {
    this.fullTalkKey = "wizwiki:ask:full-talk"
    this.fullTalkOn = this.readFullTalkPreference()
    this.activeAudioButton = null
    this.activeAudio = null
    this.knownAnswerIds = new Set()
    this.knownPrimed = false
    this.recorder = null
    this.stream = null
    this.chunks = []
    this.startingVoice = false
    this.pendingVoiceStop = false
    this.autopilotThinkingTimer = null
    this.autopilotThinkingNode = null
    this.autopilotRefreshTimer = null
    this.autopilotRefreshUntil = 0
    this.autopilotRefreshStartedAt = 0
    this.autopilotRefreshBusy = false
    this.askPendingTimer = null
    this.askPendingStartedAt = null
    this.askPendingForm = null
    this.heroProgressTimer = null

    this.boundSubmitText = this.submitText.bind(this)
    this.boundAskCopyClick = this.handleAskCopyClick.bind(this)
    this.boundScrollAutopilotThreads = () => this.scrollAutopilotThreadsIfChanged()
    this.boundThreadViewChange = (event) => {
      if (event.target?.matches?.("input[name='wizwiki_thread_view']")) {
        this.scrollAutopilotThreads()
        this.syncHeroStatus()
      }
    }
    this.boundHeroSubmitStart = this.handleHeroSubmitStart.bind(this)
    this.boundHeroSubmitEnd = this.handleHeroSubmitEnd.bind(this)
    this.element.addEventListener("submit", this.boundSubmitText)
    this.element.addEventListener("click", this.boundAskCopyClick)
    this.element.addEventListener("change", this.boundThreadViewChange)
    this.element.addEventListener("turbo:submit-start", this.boundHeroSubmitStart)
    this.element.addEventListener("turbo:submit-end", this.boundHeroSubmitEnd)
    document.addEventListener("turbo:render", this.boundScrollAutopilotThreads)
    document.addEventListener("turbo:submit-end", this.boundScrollAutopilotThreads)
    this.primeKnownAnswers()
    this.syncFullTalkControls()
    this.lastAutopilotThreadSignature = this.autopilotThreadSignature()
    this.syncHeroStatus()
    this.startHeroProgressTimer()
    this.scrollAutopilotThreads()
    this.startAnswerObserver()
    this.startAutopilotObserver()
  }

  disconnect() {
    this.stopPlayback()
    this.stopTracks()
    if (this.boundSubmitText) this.element.removeEventListener("submit", this.boundSubmitText)
    if (this.boundAskCopyClick) this.element.removeEventListener("click", this.boundAskCopyClick)
    if (this.boundThreadViewChange) this.element.removeEventListener("change", this.boundThreadViewChange)
    if (this.boundHeroSubmitStart) this.element.removeEventListener("turbo:submit-start", this.boundHeroSubmitStart)
    if (this.boundHeroSubmitEnd) this.element.removeEventListener("turbo:submit-end", this.boundHeroSubmitEnd)
    if (this.boundScrollAutopilotThreads) {
      document.removeEventListener("turbo:render", this.boundScrollAutopilotThreads)
      document.removeEventListener("turbo:submit-end", this.boundScrollAutopilotThreads)
    }
    if (this.answerObserver) this.answerObserver.disconnect()
    if (this.autopilotObserver) this.autopilotObserver.disconnect()
    this.stopAutopilotRefresh()
    this.stopAutopilotThinkingTimer()
    this.stopHeroProgressTimer()
    this.stopAskFormPending()
  }

  toggleFullTalk(event) {
    event.preventDefault()
    this.setFullTalk(!this.fullTalkOn)
  }

  stopPlayback(event) {
    if (event) event.preventDefault()

    if (this.activeAudioButton) this.resetAudioButton(this.activeAudioButton)
    this.activeAudioButton = null
    if (this.activeAudio) {
      this.activeAudio.pause()
      this.activeAudio.currentTime = 0
      this.activeAudio = null
    }

    this.element.querySelectorAll("[data-wizwiki-audio]").forEach((audio) => {
      audio.pause()
      audio.currentTime = 0
    })
  }

  async playAudio(event) {
    event.preventDefault()
    await this.playAudioButton(event.currentTarget)
  }

  async playVoiceSample(event) {
    event.preventDefault()
    const button = event.currentTarget
    const form = button.closest("form.wizwiki-ask-form")
    const selectedVoice = form?.querySelector("[data-wizwiki-voice-select]")?.value
    if (!selectedVoice) return

    button.dataset.autosAudioUrl = `/tts_samples/voice_skins/${encodeURIComponent(selectedVoice)}.wav`
    button.dataset.idleLabel = button.dataset.idleLabel || button.textContent.trim() || "TEST"
    await this.playAudioButton(button)
  }

  blockClick(event) {
    event.preventDefault()
  }

  async handleAskCopyClick(event) {
    const target = event.target instanceof Element ? event.target : event.target?.parentElement
    const button = target?.closest?.("[data-wizwiki-copy-text], [data-wizwiki-copy-thread]")
    if (!button || !this.element.contains(button)) return

    event.preventDefault()
    event.stopPropagation()

    const text = this.askCopyTextForButton(button)
    if (!text) return

    try {
      await this.writeAskClipboard(text)
      this.flashAskCopyButton(button)
    } catch (error) {
      console.warn("Could not copy Thumper text", error)
      button.textContent = "COPY FAILED"
      window.clearTimeout(button._copyResetTimer)
      button._copyResetTimer = window.setTimeout(() => {
        button.textContent = button.dataset.copyOriginalLabel || "COPY"
      }, 1400)
    }
  }

  askCopyTextForButton(button) {
    const directText = button?.dataset?.wizwikiCopyText
    if (directText) return directText

    const selector = button?.dataset?.wizwikiCopyThread
    if (!selector) return ""

    const root = document.querySelector(selector)
    if (!root) return ""

    const rows = Array.from(root.querySelectorAll("[data-wizwiki-copy-line]")).map((node, index) => ({
      index,
      text: node.dataset.wizwikiCopyLine || node.textContent.trim(),
      time: Date.parse(node.dataset.wizwikiCopyTime || "")
    }))

    const order = button.dataset.wizwikiCopyOrder
    if (order === "asc" || order === "desc") {
      rows.sort((left, right) => {
        const leftTimed = Number.isFinite(left.time)
        const rightTimed = Number.isFinite(right.time)
        if (leftTimed && rightTimed && left.time !== right.time) {
          return order === "asc" ? left.time - right.time : right.time - left.time
        }
        if (leftTimed !== rightTimed) return leftTimed ? -1 : 1
        return order === "asc" ? left.index - right.index : right.index - left.index
      })
    } else if (button.dataset.wizwikiCopyReverse === "true") {
      rows.reverse()
    }

    return rows
      .map((row) => row.text)
      .filter(Boolean)
      .join("\n\n")
  }

  async writeAskClipboard(text) {
    if (!text) return

    if (navigator.clipboard?.writeText && window.isSecureContext) {
      try {
        await navigator.clipboard.writeText(text)
        return
      } catch (_error) {
        // Fall through to the textarea fallback for browsers that expose but block Clipboard API.
      }
    }

    const field = document.createElement("textarea")
    field.value = text
    field.setAttribute("readonly", "readonly")
    field.style.position = "fixed"
    field.style.top = "0"
    field.style.left = "-9999px"
    field.style.opacity = "0"
    document.body.appendChild(field)
    field.focus({ preventScroll: true })
    field.select()
    field.setSelectionRange(0, field.value.length)
    const copied = document.execCommand("copy")
    field.remove()

    if (!copied) throw new Error("Clipboard copy command was rejected")
  }

  flashAskCopyButton(button) {
    const original = button.dataset.copyOriginalLabel || button.textContent
    button.dataset.copyOriginalLabel = original
    button.textContent = "COPIED"
    window.clearTimeout(button._copyResetTimer)
    button._copyResetTimer = window.setTimeout(() => {
      button.textContent = button.dataset.copyOriginalLabel || original
    }, 1200)
  }

  async startVoice(event) {
    event.preventDefault()
    const button = event.currentTarget
    if (button.disabled || this.startingVoice || this.recorder?.state === "recording") return

    if (!navigator.mediaDevices?.getUserMedia || !window.MediaRecorder) {
      this.setVoiceStatus("voice recording not available in this browser")
      return
    }

    this.startingVoice = true
    this.pendingVoiceStop = false

    try {
      if (event.pointerId && button.setPointerCapture) button.setPointerCapture(event.pointerId)
      this.stream = await navigator.mediaDevices.getUserMedia({ audio: true })
      this.chunks = []
      const options = MediaRecorder.isTypeSupported("audio/webm") ? { mimeType: "audio/webm" } : undefined
      this.recorder = new MediaRecorder(this.stream, options)

      this.recorder.ondataavailable = (recordEvent) => {
        if (recordEvent.data && recordEvent.data.size > 0) this.chunks.push(recordEvent.data)
      }

      this.recorder.onstop = async () => {
        this.stopTracks()
        this.setVoiceButton("ready")
        this.startingVoice = false

        if (this.chunks.length === 0) {
          this.setVoiceStatus("voice note was empty")
          return
        }

        try {
          await this.submitVoice(new Blob(this.chunks, { type: "audio/webm" }))
        } catch (_error) {
          this.setVoiceButton("ready")
          this.setVoiceStatus("voice path sparked // try again")
        }
      }

      this.recorder.start()
      this.setVoiceButton("recording")
      this.setVoiceStatus("your words are heard...")
      if (this.pendingVoiceStop) this.recorder.stop()
    } catch (_error) {
      this.startingVoice = false
      this.stopTracks()
      this.setVoiceButton("ready")
      this.setVoiceStatus("microphone permission blocked")
    }
  }

  stopVoice(event) {
    if (event) event.preventDefault()
    this.pendingVoiceStop = true
    if (this.recorder?.state === "recording") this.recorder.stop()
  }

  async submitVoice(blob) {
    const form = this.element.querySelector("form.wizwiki-ask-form")
    if (!form) return
    const autopilotReplyForm = this.isAutopilotReplyForm(form)

    const formData = new FormData(form)
    formData.set("autos_question[question]", "")
    formData.set("full_talk", this.fullTalkOn ? "1" : "0")
    formData.append("voice_blob", blob, "wizwiki_ask_voice.webm")

    this.setVoiceButton("sending")
    this.setVoiceStatus("your words are heard...")
    this.startAskFormPending(form)

    try {
      const response = await fetch(this.submitUrlFor(form), {
        method: "POST",
        credentials: "same-origin",
        headers: {
          "X-CSRF-Token": this.csrfToken(),
          "Accept": "text/vnd.turbo-stream.html"
        },
        body: formData
      })

      await this.renderTurboStream(response)
      if (autopilotReplyForm) this.extendAutopilotRefreshWindow()
      this.setVoiceButton("ready")
      this.setVoiceStatus(response.ok ? "voice prompt sent // context queue active" : "voice prompt needs another try")
      window.dispatchEvent(new CustomEvent("autos:ask-refresh"))
    } finally {
      this.stopAskFormPending(form)
    }
  }

  async submitText(event) {
    const form = event.target?.closest?.("form.wizwiki-ask-form")
    if (!form || !this.element.contains(form)) return

    this.ensureFullTalkInput(form).value = this.fullTalkOn ? "1" : "0"
    this.setVoiceStatus("Thumper reading prompt...")
    const autopilotReplyForm = this.isAutopilotReplyForm(form)
    if (autopilotReplyForm) this.extendAutopilotRefreshWindow()
    if (!autopilotReplyForm) return

    event.preventDefault()
    const submitter = event.submitter || form.querySelector("button[type=submit], input[type=submit]")
    const promptInput = form.querySelector("[data-wizwiki-prompt]")
    const formData = submitter ? new FormData(form, submitter) : new FormData(form)
    formData.set("full_talk", this.fullTalkOn ? "1" : "0")

    if (submitter) submitter.disabled = true
    this.startAskFormPending(form)
    try {
      const response = await fetch(this.submitUrlFor(form, submitter), {
        method: "POST",
        credentials: "same-origin",
        headers: {
          "X-CSRF-Token": this.csrfToken(),
          "Accept": "text/vnd.turbo-stream.html"
        },
        body: formData
      })

      const rendered = await this.renderTurboStream(response)
      this.extendAutopilotRefreshWindow()
      if (response.ok && rendered && promptInput) promptInput.value = ""
      this.setVoiceStatus(response.ok ? "test reply sent // Thumper drafting" : "test reply needs another try")
    } catch (_error) {
      this.setVoiceStatus("test reply sparked // try again")
    } finally {
      this.stopAskFormPending(form)
      if (submitter) submitter.disabled = false
      this.syncFullTalkControls()
    }
  }

  async playAudioButton(button, options = {}) {
    const url = this.audioUrlFor(button)
    if (!button || !url) return false

    const audio = button.closest("[data-wizwiki-question-id]")?.querySelector("[data-wizwiki-audio]") || new Audio(url)
    button.dataset.idleLabel = button.dataset.idleLabel || button.textContent.trim() || "👂 EAR"

    if (button.classList.contains("is-speaking")) {
      this.stopPlayback()
      return true
    }

    this.stopPlayback()
    audio.currentTime = 0
    audio.onended = () => {
      this.resetAudioButton(button)
      if (this.activeAudioButton === button) this.activeAudioButton = null
      if (this.activeAudio === audio) this.activeAudio = null
    }
    audio.onerror = audio.onended

    try {
      await audio.play()
      this.activeAudioButton = button
      this.activeAudio = audio
      button.classList.add("is-speaking")
      button.textContent = "STOP"
      button.setAttribute("aria-pressed", "true")
      return true
    } catch (_error) {
      if (!options.auto) button.textContent = "TAP AGAIN"
      this.resetAudioButton(button)
      return false
    }
  }

  maybePlayNewAnswer() {
    if (!this.fullTalkOn) return
    if (!this.knownPrimed) {
      this.primeKnownAnswers()
      return
    }

    const card = this.answerCards().find((candidate) => {
      const id = this.cardId(candidate)
      return id && !this.knownAnswerIds.has(id) && candidate.querySelector("[data-wizwiki-audio-play]")
    })
    if (!card) return

    const id = this.cardId(card)
    const button = card.querySelector("[data-wizwiki-audio-play]")
    this.knownAnswerIds.add(id)
    this.playAudioButton(button, { auto: true })
  }

  startAnswerObserver() {
    const stream = this.element.querySelector("#autos_questions")
    if (!stream) return

    this.answerObserver = new MutationObserver(() => {
      window.setTimeout(() => {
        this.syncFullTalkControls()
        this.maybePlayNewAnswer()
        this.syncHeroStatus()
      }, 0)
    })
    this.answerObserver.observe(stream, { childList: true, subtree: true })
  }

  startAutopilotObserver() {
    this.autopilotObserver = new MutationObserver(() => {
      this.scrollAutopilotThreadsIfChanged()
    })
    this.autopilotObserver.observe(this.element, { childList: true, subtree: true })
  }

  startAutopilotRefresh() {
    if (this.autopilotRefreshTimer) return

    this.autopilotRefreshTimer = window.setInterval(() => this.refreshAutopilotTest(), 3000)
  }

  async refreshAutopilotTest() {
    if (!this.shouldRefreshAutopilotTest()) return
    if (this.autopilotRefreshBusy) return

    this.autopilotRefreshBusy = true
    const panel = this.element.querySelector("#ask-autopilot-test")
    const url = panel?.dataset?.askAutopilotRefreshUrl
    if (!url) {
      this.autopilotRefreshBusy = false
      return
    }
    const refreshUrl = new URL(url, window.location.origin)
    if (panel?.dataset?.askAutopilotVersion) {
      refreshUrl.searchParams.set("version", panel.dataset.askAutopilotVersion)
    }

    try {
      const response = await fetch(refreshUrl.toString(), {
        headers: {
          "Accept": "text/vnd.turbo-stream.html",
          "X-Requested-With": "XMLHttpRequest"
        },
        credentials: "same-origin"
      })
      if (response.status === 204) return
      if (!response.ok) return

      await this.renderTurboStream(response)
      this.trimAutopilotRefreshWindow()
    } catch (_error) {
      // The next interval can try again; the simulator is read-only polling.
    } finally {
      this.autopilotRefreshBusy = false
    }
  }

  stopAutopilotRefresh() {
    if (this.autopilotRefreshTimer) window.clearInterval(this.autopilotRefreshTimer)
    this.autopilotRefreshTimer = null
    this.autopilotRefreshUntil = 0
    this.autopilotRefreshStartedAt = 0
    this.autopilotRefreshBusy = false
  }

  setFullTalk(enabled) {
    this.fullTalkOn = Boolean(enabled)
    try { window.localStorage?.setItem(this.fullTalkKey, this.fullTalkOn ? "1" : "0") } catch (_error) {}
    if (this.fullTalkOn) this.primeKnownAnswers()
    else this.stopPlayback()
    this.syncFullTalkControls()
  }

  syncFullTalkControls() {
    this.fullTalkInputTargets.forEach((input) => { input.value = this.fullTalkOn ? "1" : "0" })
    this.fullTalkToggleTargets.forEach((button) => {
      button.classList.toggle("is-on", this.fullTalkOn)
      button.setAttribute("aria-pressed", this.fullTalkOn ? "true" : "false")
    })
    this.fullTalkIconTargets.forEach((icon) => { icon.textContent = this.fullTalkOn ? "🔊" : "🔇" })
    this.fullTalkLabelTargets.forEach((label) => { label.textContent = this.fullTalkOn ? "FULL TALK ON" : "FULL TALK OFF" })
  }

  primeKnownAnswers() {
    this.answerCards().forEach((card) => {
      const id = this.cardId(card)
      if (id) this.knownAnswerIds.add(id)
    })
    this.knownPrimed = true
  }

  resetAudioButton(button) {
    if (!button) return
    button.classList.remove("is-speaking")
    button.textContent = button.dataset.idleLabel || "👂 EAR"
    button.setAttribute("aria-pressed", "false")
  }

  setVoiceButton(state) {
    this.voiceButtonTargets.forEach((button) => button.classList.toggle("is-recording", state === "recording"))
    this.voiceIconTargets.forEach((icon) => { icon.textContent = state === "recording" ? "📡" : "📻" })
    this.voiceLabelTargets.forEach((label) => {
      label.textContent = state === "recording" ? "release to send" : state === "sending" ? "sending voice" : "hold to talk"
    })
  }

  setVoiceStatus(text) {
    this.voiceStatusTargets.forEach((status) => { status.textContent = text || "" })
  }

  stopTracks() {
    if (this.stream) this.stream.getTracks().forEach((track) => track.stop())
    this.stream = null
  }

  async renderTurboStream(response) {
    const html = await response.text()
    if (response.ok && html && Turbo.renderStreamMessage) {
      const beforeSignature = this.autopilotThreadSignature()
      Turbo.renderStreamMessage(html)
      window.setTimeout(() => {
        this.syncFullTalkControls()
        this.scrollAutopilotThreadsIfChanged(beforeSignature)
        this.syncHeroStatus()
      }, 0)
      return true
    }
    return false
  }

  submitUrlFor(form, submitter = null) {
    if (submitter?.formAction) return submitter.formAction

    return form?.dataset?.autosSubmitUrl || form?.action || this.askUrlValue
  }

  isAutopilotReplyForm(form) {
    const action = form?.action || ""
    return action.includes("/ask/autopilot-test/reply")
  }

  ensureFullTalkInput(form) {
    let input = form.querySelector("input[name='full_talk']")
    if (!input) {
      input = document.createElement("input")
      input.type = "hidden"
      input.name = "full_talk"
      form.appendChild(input)
    }
    return input
  }

  scrollAutopilotThreads() {
    const scroll = () => {
      this.sortAutopilotThreads()
      this.element.querySelectorAll("[data-ask-autopilot-thread]").forEach((thread) => {
        this.pinAutopilotThreadToTop(thread)
      })
    }

    scroll()
    window.requestAnimationFrame(scroll)
    window.setTimeout(scroll, 20)
    window.setTimeout(scroll, 80)
    window.setTimeout(scroll, 240)
    window.setTimeout(scroll, 700)
    window.setTimeout(scroll, 1400)
  }

  pinAutopilotThreadToTop(thread) {
    if (!thread) return

    const previousBehavior = thread.style.scrollBehavior
    thread.style.scrollBehavior = "auto"
    thread.scrollTop = 0
    if (thread.scrollTo) thread.scrollTo({ top: 0, left: 0, behavior: "auto" })
    thread.dataset.wizwikiPinnedTopAt = Date.now().toString()

    window.requestAnimationFrame(() => {
      thread.scrollTop = 0
      if (previousBehavior) thread.style.scrollBehavior = previousBehavior
      else thread.style.removeProperty("scroll-behavior")
    })
  }

  sortAutopilotThreads() {
    this.element.querySelectorAll("[data-ask-autopilot-thread]").forEach((thread) => {
      const rows = Array.from(thread.querySelectorAll("[data-wizwiki-copy-time]"))
      if (rows.length < 2) return

      rows
        .map((row, index) => ({
          index,
          row,
          time: Date.parse(row.dataset.wizwikiCopyTime || "")
        }))
        .sort((left, right) => {
          const leftTimed = Number.isFinite(left.time)
          const rightTimed = Number.isFinite(right.time)
          if (leftTimed && rightTimed && left.time !== right.time) return right.time - left.time
          if (leftTimed !== rightTimed) return leftTimed ? -1 : 1
          return left.index - right.index
        })
        .forEach(({ row }) => thread.appendChild(row))
    })
  }

  scrollAutopilotThreadsIfChanged(previousSignature = this.lastAutopilotThreadSignature) {
    if (typeof previousSignature !== "string") previousSignature = this.lastAutopilotThreadSignature
    const nextSignature = this.autopilotThreadSignature()
    if (nextSignature && nextSignature === previousSignature) return

    this.lastAutopilotThreadSignature = nextSignature
    this.scrollAutopilotThreads()
  }

  autopilotThreadSignature() {
    const panel = this.element.querySelector("#ask-autopilot-test")
    const thread = panel?.querySelector("[data-ask-autopilot-thread]")
    return [
      panel?.dataset?.askAutopilotVersion || "",
      panel?.dataset?.askAutopilotPending || "",
      thread?.textContent?.replace(/\s+/g, " ").trim() || ""
    ].join("|")
  }

  autopilotDraftPending() {
    return Boolean(this.element.querySelector("[data-ask-autopilot-pending='true']"))
  }

  shouldRefreshAutopilotTest() {
    const panel = this.element.querySelector("#ask-autopilot-test")
    if (!this.autopilotDraftPending() && this.autopilotRefreshStartedAt > 0 && Date.now() > this.autopilotRefreshStartedAt + 20000) {
      this.stopAutopilotRefresh()
      return false
    }

    return Boolean(panel?.dataset?.askAutopilotRefreshUrl) &&
      (this.autopilotDraftPending() || Date.now() < this.autopilotRefreshUntil)
  }

  extendAutopilotRefreshWindow(milliseconds = 45000) {
    this.autopilotRefreshStartedAt = this.autopilotRefreshStartedAt || Date.now()
    this.autopilotRefreshUntil = Math.max(this.autopilotRefreshUntil || 0, Date.now() + milliseconds)
    this.startAutopilotRefresh()
    window.setTimeout(() => this.refreshAutopilotTest(), 0)
  }

  trimAutopilotRefreshWindow() {
    if (this.autopilotDraftPending()) return

    const stopSoon = Date.now() + 6000
    this.autopilotRefreshUntil = this.autopilotRefreshUntil > 0 ? Math.min(this.autopilotRefreshUntil, stopSoon) : stopSoon
  }

  syncAutopilotThinkingTimer() {
    const nodes = this.visibleAutopilotThinkingNodes()
    if (nodes.length === 0) {
      this.stopAutopilotThinkingTimer()
      return
    }

    if (this.autopilotThinkingTimer) {
      this.updateAutopilotThinkingTimer()
      return
    }

    this.stopAutopilotThinkingTimer()
    this.updateAutopilotThinkingTimer()
    this.autopilotThinkingTimer = window.setInterval(() => this.updateAutopilotThinkingTimer(), 1000)
  }

  stopAutopilotThinkingTimer() {
    if (this.autopilotThinkingTimer) window.clearInterval(this.autopilotThinkingTimer)
    this.autopilotThinkingTimer = null
    this.autopilotThinkingNode = null
  }

  updateAutopilotThinkingTimer() {
    const nodes = this.visibleAutopilotThinkingNodes()
    if (nodes.length === 0) {
      this.stopAutopilotThinkingTimer()
      return
    }

    nodes.forEach((node) => {
      const timer = node.querySelector("[data-ask-autopilot-thinking-timer]")
      const bar = node.querySelector("[data-ask-autopilot-thinking-bar]")
      const startedAt = this.autopilotThinkingStartedAt(node)
      const elapsedSeconds = Math.max(0, Math.floor((Date.now() - startedAt) / 1000))
      this.setTextIfChanged(timer, this.formatAutopilotThinkingDuration(elapsedSeconds))
      this.setWidthIfChanged(bar, `${Math.min(96, 14 + elapsedSeconds * 2.4)}%`)
      this.updateAutopilotElapsedTimers(node)
    })
  }

  autopilotThinkingStartedAt(node) {
    const panel = node.closest("#ask-autopilot-test")
    const raw = node.dataset.askAutopilotThinkingStartedAt || panel?.dataset?.askAutopilotPendingStartedAt || ""
    const parsed = Date.parse(raw)
    return Number.isNaN(parsed) ? Date.now() : parsed
  }

  visibleAutopilotThinkingNodes() {
    return Array.from(this.element.querySelectorAll("[data-ask-autopilot-thinking]")).filter((node) => this.elementVisible(node))
  }

  elementVisible(node) {
    if (!node || node.classList?.contains("hidden")) return false
    const style = window.getComputedStyle(node)
    return style.display !== "none" && style.visibility !== "hidden" && style.opacity !== "0"
  }

  updateAutopilotElapsedTimers(node) {
    node.querySelectorAll("[data-ask-autopilot-elapsed-timer]").forEach((timer) => {
      const parsed = Date.parse(timer.dataset.askAutopilotElapsedStartedAt || "")
      if (Number.isNaN(parsed)) return

      const elapsedSeconds = Math.max(0, Math.floor((Date.now() - parsed) / 1000))
      this.setTextIfChanged(timer, this.formatAutopilotThinkingDuration(elapsedSeconds))
    })
  }

  formatAutopilotThinkingDuration(seconds) {
    const minutes = Math.floor(seconds / 60).toString().padStart(2, "0")
    const remainder = Math.floor(seconds % 60).toString().padStart(2, "0")
    return `${minutes}:${remainder}`
  }

  startAskFormPending(form) {
    const pending = form?.querySelector("[data-autos-chat-target~='pending']")
    if (!pending) return

    if (this.askPendingTimer) window.clearInterval(this.askPendingTimer)
    this.askPendingForm = form
    this.askPendingStartedAt = Date.now()
    pending.classList.remove("hidden")
    if (this.isAutopilotReplyForm(form)) this.showHeroSmsProgress(new Date(this.askPendingStartedAt).toISOString(), true)
    else this.showHeroAskProgress(new Date(this.askPendingStartedAt).toISOString(), true)
    this.syncHeroStatus()
    this.startHeroProgressTimer()
    this.updateAskFormPendingTimer()
    this.askPendingTimer = window.setInterval(() => this.updateAskFormPendingTimer(), 1000)
  }

  stopAskFormPending(form = this.askPendingForm) {
    if (this.askPendingTimer) window.clearInterval(this.askPendingTimer)
    this.askPendingTimer = null
    this.askPendingStartedAt = null

    const pending = form?.querySelector("[data-autos-chat-target~='pending']")
    if (pending) pending.classList.add("hidden")
    this.setAskFormPendingTimerText(form, "00:00")
    this.clearTransientHeroProgress(form)
    this.syncHeroStatus()
    if (!form || form === this.askPendingForm) this.askPendingForm = null
  }

  updateAskFormPendingTimer() {
    if (!this.askPendingStartedAt) return
    const elapsedSeconds = Math.max(0, Math.floor((Date.now() - this.askPendingStartedAt) / 1000))
    this.setAskFormPendingTimerText(this.askPendingForm, this.formatAutopilotThinkingDuration(elapsedSeconds))
  }

  setAskFormPendingTimerText(form, text) {
    form?.querySelectorAll("[data-autos-chat-target~='timer']").forEach((timer) => {
      this.setTextIfChanged(timer, text)
    })
  }

  handleHeroSubmitStart(event) {
    const form = event.target
    if (!(form instanceof HTMLFormElement) || !this.element.contains(form)) return
    if (!form.matches("[data-wizwiki-ask-form]")) return

    const startedAt = new Date().toISOString()
    if (this.isAutopilotReplyForm(form)) this.showHeroSmsProgress(startedAt, true)
    else this.showHeroAskProgress(startedAt, true)
    this.syncHeroStatus()
    this.startHeroProgressTimer()
  }

  handleHeroSubmitEnd(event) {
    const form = event.target
    if (!(form instanceof HTMLFormElement) || !this.element.contains(form)) return
    if (!form.matches("[data-wizwiki-ask-form]")) return

    window.setTimeout(() => {
      this.clearTransientHeroProgress(form)
      this.syncHeroStatus()
    }, 0)
    window.setTimeout(() => {
      this.clearTransientHeroProgress(form)
      this.syncHeroStatus()
    }, 800)
  }

  syncHeroStatus() {
    const hero = this.heroElement()
    if (!hero) return

    this.syncHeroProgressFromDom()

    const selected = this.selectedThreadView()
    const smsPending = this.heroProgressVisible(this.heroSmsProgress())
    const askPending = this.heroProgressVisible(this.heroAskProgress())
    const label = hero.querySelector("[data-wizwiki-hero-label]")
    const note = hero.querySelector("[data-wizwiki-hero-note]")

    hero.classList.toggle("is-drafting", smsPending || askPending)
    if (label) {
      this.setTextIfChanged(label, selected === "ask"
        ? hero.dataset[askPending ? "askPendingLabel" : "askReadyLabel"] || "Ask thread ready"
        : hero.dataset[smsPending ? "smsPendingLabel" : "smsReadyLabel"] || "SMS simulator ready")
    }
    if (note) {
      this.setTextIfChanged(note, selected === "ask"
        ? hero.dataset[askPending ? "askPendingNote" : "askReadyNote"] || "Thumper vector context ready"
        : hero.dataset[smsPending ? "smsPendingNote" : "smsReadyNote"] || "real engine // no twilio")
    }

    this.updateHeroProgressTimers()
  }

  syncHeroProgressFromDom() {
    const panel = this.element.querySelector("#ask-autopilot-test")
    const smsRow = this.heroSmsProgress()
    const smsPanelPending = panel?.dataset?.askAutopilotPending === "true"
    if (smsPanelPending) {
      this.showHeroSmsProgress(panel.dataset.askAutopilotPendingStartedAt || new Date().toISOString())
    } else if (!this.heroProgressTransient(smsRow) || this.heroProgressTransientExpired(smsRow)) {
      this.hideHeroProgress(smsRow)
    }

    const askRow = this.heroAskProgress()
    const askPendingNode = this.element.querySelector("#autos_questions [data-autos-question-pending='true'] [data-wizwiki-processing-since]")
    if (askPendingNode?.dataset?.wizwikiProcessingSince) {
      this.showHeroAskProgress(askPendingNode.dataset.wizwikiProcessingSince)
    } else if (!this.heroProgressTransient(askRow) || this.heroProgressTransientExpired(askRow)) {
      this.hideHeroProgress(askRow)
    }
  }

  showHeroSmsProgress(startedAt = new Date().toISOString(), transient = false) {
    this.showHeroProgress(this.heroSmsProgress(), "askAutopilotThinkingStartedAt", startedAt, transient)
  }

  showHeroAskProgress(startedAt = new Date().toISOString(), transient = false) {
    this.showHeroProgress(this.heroAskProgress(), "wizwikiProcessingSince", startedAt, transient)
  }

  showHeroProgress(row, startedAtKey, startedAt, transient = false) {
    if (!row) return
    row.classList.remove("hidden")
    row.dataset[startedAtKey] = startedAt || new Date().toISOString()
    if (transient) {
      row.dataset.wizwikiHeroTransient = "true"
      row.dataset.wizwikiHeroTransientStartedAt = Date.now().toString()
    }
  }

  hideHeroProgress(row) {
    if (!row) return
    row.classList.add("hidden")
    delete row.dataset.wizwikiHeroTransient
    delete row.dataset.wizwikiHeroTransientStartedAt
    delete row.dataset.askAutopilotThinkingStartedAt
    delete row.dataset.wizwikiProcessingSince
    this.setTextIfChanged(row.querySelector("[data-ask-autopilot-thinking-timer]"), "00:00")
    this.setTextIfChanged(row.querySelector("[data-wizwiki-processing-timer]"), "00:00")
    this.setWidthIfChanged(row.querySelector("[data-ask-autopilot-thinking-bar]"), "0%")
    this.setWidthIfChanged(row.querySelector("[data-wizwiki-processing-bar]"), "0%")
  }

  clearTransientHeroProgress(form) {
    const row = this.isAutopilotReplyForm(form) ? this.heroSmsProgress() : this.heroAskProgress()
    if (!this.heroProgressTransient(row)) return
    this.hideHeroProgress(row)
  }

  heroProgressVisible(row) {
    return Boolean(row && !row.classList.contains("hidden"))
  }

  heroProgressTransient(row) {
    return row?.dataset?.wizwikiHeroTransient === "true"
  }

  heroProgressTransientExpired(row, milliseconds = 12000) {
    if (!this.heroProgressTransient(row)) return false
    const startedAt = Number.parseInt(row.dataset.wizwikiHeroTransientStartedAt || "0", 10)
    return !Number.isFinite(startedAt) || startedAt <= 0 || Date.now() - startedAt > milliseconds
  }

  selectedThreadView() {
    return this.element.querySelector("#wizwiki-thread-ask:checked") ? "ask" : "sms"
  }

  heroElement() {
    return this.element.querySelector("[data-wizwiki-ask-hero]")
  }

  heroSmsProgress() {
    return this.heroElement()?.querySelector("[data-wizwiki-hero-sms-progress]")
  }

  heroAskProgress() {
    return this.heroElement()?.querySelector("[data-wizwiki-hero-ask-progress]")
  }

  startHeroProgressTimer() {
    this.updateHeroProgressTimers()
    if (this.heroProgressTimer) return
    this.heroProgressTimer = window.setInterval(() => {
      this.syncHeroStatus()
      this.updateHeroProgressTimers()
    }, 1000)
  }

  stopHeroProgressTimer() {
    if (this.heroProgressTimer) window.clearInterval(this.heroProgressTimer)
    this.heroProgressTimer = null
  }

  updateHeroProgressTimers() {
    this.updateAutopilotThinkingTimer()
    this.element.querySelectorAll("[data-wizwiki-hero-ask-progress]").forEach((row) => {
      const startedAt = Date.parse(row.dataset.wizwikiProcessingSince || "")
      if (Number.isNaN(startedAt)) return

      const elapsedSeconds = Math.max(0, Math.floor((Date.now() - startedAt) / 1000))
      const timer = row.querySelector("[data-wizwiki-processing-timer]")
      const bar = row.querySelector("[data-wizwiki-processing-bar]")
      this.setTextIfChanged(timer, this.formatAutopilotThinkingDuration(elapsedSeconds))
      this.setWidthIfChanged(bar, `${Math.min(96, 14 + elapsedSeconds * 2.4)}%`)
    })
  }

  setTextIfChanged(node, text) {
    if (!node) return
    const next = text || ""
    if (node.textContent !== next) node.textContent = next
  }

  setWidthIfChanged(node, width) {
    if (!node) return
    if (node.style.width !== width) node.style.width = width
  }

  readFullTalkPreference() {
    try { return window.localStorage?.getItem(this.fullTalkKey) === "1" } catch (_error) { return false }
  }

  csrfToken() {
    return document.querySelector("meta[name='csrf-token']")?.content || ""
  }

  answerCards() {
    return Array.from(this.element.querySelectorAll("[data-wizwiki-answer-ready='true']"))
  }

  cardId(card) {
    return card?.dataset?.wizwikiQuestionId || ""
  }

  audioUrlFor(button) {
    return button?.dataset?.autosAudioUrl || button?.closest("[data-wizwiki-question-id]")?.querySelector("[data-wizwiki-audio]")?.src || ""
  }
}
