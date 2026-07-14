import { Controller } from "@hotwired/stimulus"

const THUMPER_COMMS_STATION_RUNTIME_VERSION = "2026-06-23.1"
const CLIENT_DRAFT_TIMEOUT_MS = 2 * 60 * 1000

export default class extends Controller {
  static targets = ["progress", "progressMessage", "progressTimer"]

  static values = {
    interval: { type: Number, default: 5000 },
    stageId: String,
    url: String,
    version: String,
    watch: { type: Boolean, default: false },
  }

  connect() {
    this.submit = this.submit.bind(this)
    this.change = this.change.bind(this)
    this.toggle = this.toggle.bind(this)
    this.click = this.click.bind(this)
    this.pointerdown = this.pointerdown.bind(this)
    this.keydown = this.keydown.bind(this)
    this.refresh = this.refresh.bind(this)
    this.deactivateForOtherStation = this.deactivateForOtherStation.bind(this)
    this.refreshTimer = null
    this.syncPulseTimer = null
    this.syncPulseHideTimer = null
    this.refreshInFlight = false
    this.progressDeadlineTimer = null
    this.clientProgressTimedOut = false
    this.element.addEventListener("submit", this.submit, true)
    this.element.addEventListener("change", this.change, true)
    this.element.addEventListener("toggle", this.toggle, true)
    this.element.addEventListener("pointerdown", this.pointerdown, true)
    this.element.addEventListener("touchstart", this.pointerdown, { capture: true, passive: true })
    this.element.addEventListener("click", this.click, true)
    this.element.addEventListener("keydown", this.keydown, true)
    document.addEventListener("comms:station-activate", this.deactivateForOtherStation)
    this.startPollingIfOpen()
    this.scrollPhoneChatToEnd()
    this.resumeDraftProgressTimerIfActive()
    this.startAttentionTimer()
  }

  disconnect() {
    this.element.removeEventListener("submit", this.submit, true)
    this.element.removeEventListener("change", this.change, true)
    this.element.removeEventListener("toggle", this.toggle, true)
    this.element.removeEventListener("pointerdown", this.pointerdown, true)
    this.element.removeEventListener("touchstart", this.pointerdown, { capture: true })
    this.element.removeEventListener("click", this.click, true)
    this.element.removeEventListener("keydown", this.keydown, true)
    document.removeEventListener("comms:station-activate", this.deactivateForOtherStation)
    this.stopPolling()
    this.stopProgress()
    this.stopSyncPulse({ immediate: true })
    this.stopAttentionTimer()
    if (this.progressErrorTimer) window.clearTimeout(this.progressErrorTimer)
  }

  confirmFormSubmission(form, event) {
    if (!(form instanceof HTMLFormElement)) return true

    const submitter = event?.submitter || (event?.target instanceof Element ? event.target.closest("button, input[type='submit']") : null)
    const message = form.dataset.commsConfirmMessage ||
      form.dataset.turboConfirm ||
      submitter?.dataset?.commsConfirmMessage ||
      submitter?.dataset?.turboConfirm
    if (!message) return true

    if (form.dataset.commsConfirmed === "true") {
      this.suppressTurboConfirm(form, submitter)
      window.setTimeout(() => {
        delete form.dataset.commsConfirmed
      }, 0)
      return true
    }

    if (window.confirm(message)) {
      form.dataset.commsConfirmed = "true"
      this.suppressTurboConfirm(form, submitter)
      return true
    }

    event?.preventDefault()
    event?.stopPropagation()
    event?.stopImmediatePropagation?.()
    return false
  }

  suppressTurboConfirm(form, submitter = null) {
    if (form?.dataset) delete form.dataset.turboConfirm
    if (submitter?.dataset) delete submitter.dataset.turboConfirm
  }

  async submit(event) {
    const form = event.target
    if (!(form instanceof HTMLFormElement)) return
    if (!this.confirmFormSubmission(form, event)) return
    if (form.matches('[data-comms-delete-form="true"], .comms-command-delete-form')) {
      this.prepareDeleteForm(form, event.submitter)
      return
    }
    if (form.matches(".comms-command-send-sms-form")) return
    if (!form.closest(".comms-command-communicator")) return

    event.preventDefault()
    event.stopPropagation()
    event.stopImmediatePropagation?.()
    await this.submitPhoneForm(form, event.submitter)
  }

  change(event) {
    const select = event.target
    if (!(select instanceof HTMLSelectElement)) return
    if (select.matches("[data-sms-writer-select]")) {
      this.syncSmsWriterModel(select.value)
      this.saveSmsWriterModel(select)
      return
    }
    if (select.matches("[data-rag-profile-select]")) this.saveRagProfile(select)
  }

  async saveRagProfile(select) {
    const url = select.dataset.ragProfileUrl
    const profile = select.value
    if (!url || !profile) return

    const sequence = (this.ragProfileSaveSequence || 0) + 1
    this.ragProfileSaveSequence = sequence
    select.dataset.commsSaving = "true"
    delete select.dataset.commsSaveError

    const data = new FormData()
    data.append("rag_profile", profile)

    try {
      const response = await fetch(url, {
        method: "PATCH",
        body: data,
        credentials: "same-origin",
        headers: {
          "Accept": "text/html",
          "X-CSRF-Token": this.csrfToken(),
          "X-Requested-With": "XMLHttpRequest",
        },
      })
      if (!response.ok) throw new Error(`HTTP ${response.status}`)
      const html = await response.text()
      if (html) this.patchLiveSectionsFromHtml(html, { scrollChatToEnd: false, force: true })
      if (this.ragProfileSaveSequence === sequence) delete select.dataset.commsSaving
    } catch (error) {
      if (this.ragProfileSaveSequence === sequence) {
        select.dataset.commsSaveError = "true"
        delete select.dataset.commsSaving
      }
      console.warn("Could not save SMS RAG profile", error)
    }
  }

  async saveSmsWriterModel(select) {
    const url = select.dataset.smsWriterModelUrl
    const model = select.value
    if (!url || !model) return

    this.pendingSmsWriterModel = model
    const sequence = (this.smsWriterModelSaveSequence || 0) + 1
    this.smsWriterModelSaveSequence = sequence
    select.dataset.commsSaving = "true"
    delete select.dataset.commsSaveError

    const data = new FormData()
    data.append("sms_writer_model", model)

    try {
      const response = await fetch(url, {
        method: "PATCH",
        body: data,
        credentials: "same-origin",
        headers: {
          "Accept": "text/html",
          "X-CSRF-Token": this.csrfToken(),
          "X-Requested-With": "XMLHttpRequest",
        },
      })

      if (!response.ok) throw new Error(`HTTP ${response.status}`)
      const html = await response.text()
      if (html) this.patchLiveSectionsFromHtml(html, { scrollChatToEnd: false, force: true })
      if (this.smsWriterModelSaveSequence === sequence) {
        delete this.pendingSmsWriterModel
        delete select.dataset.commsSaving
      }
      this.syncSmsWriterModel(model)
    } catch (error) {
      if (this.smsWriterModelSaveSequence === sequence) {
        select.dataset.commsSaveError = "true"
        delete select.dataset.commsSaving
      }
      console.warn("Could not save SMS writer model", error)
    }
  }

  syncSmsWriterModel(model = null, root = this.element) {
    const selected = model || this.currentSmsWriterModel(root)
    if (!selected) return

    root.querySelectorAll("[data-sms-writer-stage]").forEach((control) => {
      if (control instanceof HTMLSelectElement) {
        if (Array.from(control.options).some((option) => option.value === selected)) control.value = selected
        return
      }

      if (control instanceof HTMLInputElement) control.value = selected
    })

    root.querySelectorAll("[data-sms-runtime-model]").forEach((button) => {
      if (!(button instanceof HTMLButtonElement)) return

      const active = button.dataset.smsRuntimeModel === selected
      button.classList.toggle("is-active", active)
      button.setAttribute("aria-pressed", active ? "true" : "false")
    })
  }

  currentSmsWriterModel(root = this.element) {
    const select = root.querySelector("[data-sms-writer-select]")
    if (select instanceof HTMLSelectElement && select.value) return select.value

    const hidden = root.querySelector("input[data-sms-writer-stage]")
    if (hidden instanceof HTMLInputElement && hidden.value) return hidden.value

    return ""
  }

  csrfToken() {
    return document.querySelector("meta[name='csrf-token']")?.content || ""
  }

  async submitFromButton(event) {
    const button = event.target instanceof Element ? event.target.closest("button, input[type='submit']") : null
    const form = button?.closest("form")
    if (!(form instanceof HTMLFormElement)) return
    if (!form.closest(".comms-command-communicator")) return

    event.preventDefault()
    event.stopPropagation()
    event.stopImmediatePropagation?.()
    await this.submitPhoneForm(form, button)
  }

  toggle(event) {
    if (!(event.target instanceof HTMLDetailsElement)) return
    if (!event.target.querySelector(".comms-command-communicator--phone")) return

    if (event.target.open) {
      this.watchValue = true
      this.announceActiveStation()
      this.startPolling()
      this.scrollPhoneChatToEnd()
    } else {
      this.watchValue = false
      this.stopPolling()
      this.hideLiveProgress()
    }
  }

  async click(event) {
    const copyButton = event.target instanceof Element ? event.target.closest("[data-copy-text], [data-copy-thread-selector]") : null
    if (copyButton) {
      await this.copyText(event)
      return
    }

    const runtimeButton = event.target instanceof Element ? event.target.closest("[data-sms-runtime-model]") : null
    if (runtimeButton instanceof HTMLButtonElement) {
      event.preventDefault()
      event.stopPropagation()
      event.stopImmediatePropagation?.()
      this.selectSmsWriterModel(runtimeButton)
      return
    }

    const attentionButton = event.target instanceof Element ? event.target.closest(".comms-command-icon-button--attn") : null
    if (attentionButton) {
      event.preventDefault()
      event.stopPropagation()
      event.stopImmediatePropagation?.()
      this.openSmsOverlaySoon(this.element.querySelector(".comms-command-icon-button--sms"))
      return
    }

    const submitter = event.target instanceof Element ? event.target.closest("button, input[type='submit']") : null
    const confirmForm = submitter?.closest("form")
    if (confirmForm instanceof HTMLFormElement && !this.confirmFormSubmission(confirmForm, event)) return

    const closeButton = event.target instanceof Element ? event.target.closest(".comms-command-overlay-close") : null
    if (closeButton) {
      this.closeOverlay(event)
      return
    }

    const smsSummary = event.target instanceof Element ? event.target.closest(".comms-command-icon-button--sms") : null
    if (smsSummary) {
      event.preventDefault()
      event.stopPropagation()
      event.stopImmediatePropagation?.()
      this.openSmsOverlaySoon(smsSummary)
      return
    }

    const rewriteButton = event.target instanceof Element ? event.target.closest(".comms-command-send--rewrite") : null
    if (rewriteButton) {
      const form = rewriteButton.closest("form")
      if (form instanceof HTMLFormElement && form.closest(".comms-command-communicator--phone")) {
        this.primeDraftProgress(rewriteButton)
        await this.submitFromButton(event)
        return
      }
    }

    const detailsBackdrop = event.target instanceof HTMLDetailsElement ? event.target : null
    if (detailsBackdrop?.classList.contains("comms-command-details") && detailsBackdrop.open) {
      this.closeOverlay(event)
    }
  }

  selectSmsWriterModel(button) {
    const model = button.dataset.smsRuntimeModel
    const select = this.element.querySelector("[data-sms-writer-select]")
    if (!model || !(select instanceof HTMLSelectElement)) return
    if (!Array.from(select.options).some((option) => option.value === model)) return

    select.value = model
    this.syncSmsWriterModel(model)
    select.dispatchEvent(new Event("change", { bubbles: true }))
  }

  pointerdown(event) {
    const rewriteButton = event.target instanceof Element ? event.target.closest(".comms-command-send--rewrite") : null
    if (!rewriteButton) return

    const form = rewriteButton.closest("form")
    if (!(form instanceof HTMLFormElement) || !form.closest(".comms-command-communicator--phone")) return

    this.watchValue = true
    this.primeDraftProgress(rewriteButton, "Thumper COMPOSING")
  }

  keydown(event) {
    if (event.key !== "Escape") return
    if (!this.element.querySelector(".comms-command-details[open]")) return

    this.closeOverlay(event)
  }

  closeOverlay(event) {
    event.preventDefault()
    event.stopPropagation()
    event.stopImmediatePropagation?.()

    const source = event.target instanceof Element ? event.target : null
    const details = source?.closest(".comms-command-details")
    const openDetails = details instanceof HTMLDetailsElement ? [details] : Array.from(this.element.querySelectorAll(".comms-command-details[open]"))

    openDetails.forEach((item) => {
      if (item instanceof HTMLDetailsElement) item.open = false
    })

    this.clearOpenOverlayParams()
    this.watchValue = false
    this.stopPolling()
    this.hideLiveProgress()
  }

  prepareDeleteForm(form, submitter = null) {
    const row = form.closest(".comms-command-row") || this.element
    const popover = form.closest("[popover]")

    if (popover instanceof HTMLElement) {
      try {
        if (typeof popover.hidePopover === "function") popover.hidePopover()
      } catch (_) {
      }
      popover.classList.add("comms-command-confirm-popover--closing")
    }

    row.classList.add("comms-command-row--deleting")
    row.setAttribute("aria-busy", "true")
    row.querySelectorAll(".comms-command-details[open]").forEach((item) => {
      if (item instanceof HTMLDetailsElement) item.open = false
    })

    this.clearOpenOverlayParams()
    this.watchValue = false
    this.stopPolling()
    this.hideLiveProgress()

    const label = "DELETING..."
    if (submitter instanceof HTMLInputElement) {
      submitter.value = label
    } else if (submitter instanceof HTMLButtonElement) {
      submitter.textContent = label
    }

    form.querySelectorAll("button, input, select, textarea").forEach((control) => {
      if (control instanceof HTMLInputElement && control.type === "hidden") return
      if (control instanceof HTMLButtonElement || control instanceof HTMLInputElement || control instanceof HTMLSelectElement || control instanceof HTMLTextAreaElement) {
        control.disabled = true
      }
    })

    window.setTimeout(() => {
      row.classList.add("comms-command-row--delete-collapsing")
    }, 120)
  }

  clearOpenOverlayParams() {
    const url = new URL(window.location.href)
    const hadOpenParam = url.searchParams.has("open_sms_stage") || url.searchParams.has("open_email_stage")
    url.searchParams.delete("open_sms_stage")
    url.searchParams.delete("open_email_stage")
    if (hadOpenParam) window.history.replaceState(window.history.state, "", `${url.pathname}${url.search}${url.hash}`)
  }

  startPollingIfOpen() {
    if (this.stationActive()) {
      this.announceActiveStation()
      this.startPolling()
      this.scrollPhoneChatToEnd()
    }
  }

  stationActive() {
    return this.watchValue || !!this.phoneDetails()?.open
  }

  stationIdentifier() {
    return this.stageIdValue || this.element.id?.replace(/^stage-/, "") || ""
  }

  announceActiveStation() {
    const stageId = this.stationIdentifier()
    if (!stageId) return

    document.dispatchEvent(new CustomEvent("comms:station-activate", { detail: { stageId } }))
  }

  deactivateForOtherStation(event) {
    const activeStageId = event?.detail?.stageId?.toString()
    if (!activeStageId || activeStageId === this.stationIdentifier().toString()) return

    this.watchValue = false
    const details = this.phoneDetails()
    if (details instanceof HTMLDetailsElement && details.open) details.open = false
    this.stopPolling()
    this.hideLiveProgress()
  }


  startPolling() {
    if (this.poller) return
    this.refreshSoon(120)
    this.poller = window.setInterval(this.refresh, this.intervalValue)
  }

  stopPolling() {
    if (this.refreshTimer) window.clearTimeout(this.refreshTimer)
    this.refreshTimer = null
    if (!this.poller) return
    window.clearInterval(this.poller)
    this.poller = null
  }

  refreshSoon(delay = 0) {
    if (this.refreshTimer) window.clearTimeout(this.refreshTimer)
    this.refreshTimer = window.setTimeout(() => {
      this.refreshTimer = null
      this.refresh()
    }, delay)
  }

  openSmsOverlaySoon(source = null) {
    this.watchValue = true
    this.announceActiveStation()
    const details = source instanceof Element ? source.closest(".comms-command-details") : this.phoneDetails()
    if (details instanceof HTMLDetailsElement) details.open = true
    this.setOpenSmsParam()
    this.startPolling()
    this.refreshSoon(0)
    this.scrollPhoneChatToEnd({ includeNewest: true })
    window.setTimeout(() => {
      if (!this.stationActive()) return
      this.startPolling()
      this.refreshSoon(0)
      this.scrollPhoneChatToEnd({ includeNewest: true })
    }, 80)
    window.setTimeout(() => this.scrollPhoneChatToEnd({ includeNewest: true }), 220)
    window.setTimeout(() => this.scrollPhoneChatToEnd({ includeNewest: true }), 520)
  }

  setOpenSmsParam() {
    const stageId = this.stageIdValue || this.element.id?.replace(/^stage-/, "")
    if (!stageId) return

    try {
      const url = new URL(window.location.href)
      url.searchParams.set("open_sms_stage", stageId)
      url.searchParams.delete("open_email_stage")
      url.hash = `stage-${stageId}`
      window.history.replaceState(window.history.state, "", `${url.pathname}${url.search}${url.hash}`)
    } catch (_) {
    }
  }

  async submitPhoneForm(form, submitter) {
    const openIndex = this.detailsIndex(form.closest(".comms-command-details"))
    const preservePhoneOverlay = !!form.closest(".comms-command-communicator--phone")
    const draftRequest = this.isSmsDraftForm(form)
    let keepDraftProgress = false
    const scrollState = this.captureScrollState()
    const wasPolling = !!this.poller
    this.stopPolling()
    this.setBusy(form, true)
    this.startProgress(this.progressLabelFor(form, submitter))

    try {
      const response = await fetch(form.action, {
        method: form.method || "post",
        body: this.formData(form, submitter),
        credentials: "same-origin",
        headers: {
          "Accept": "text/html",
          "X-Requested-With": "XMLHttpRequest",
        },
      })

      if (!response.ok) throw new Error(`HTTP ${response.status}`)
      const html = await response.text()
      const draftChanged = draftRequest && this.htmlDraftKeyChanged(html)
      keepDraftProgress = draftRequest && (this.htmlShowsDrafting(html) || !draftChanged)
      if (draftRequest) {
        this.patchLiveSectionsFromHtml(html, { scrollState, scrollChatToEnd: true, force: true })
      } else {
        this.replaceFromHtml(html, { force: true, openIndex, preservePhoneOverlay, scrollState, scrollChatToEnd: preservePhoneOverlay })
      }
    } catch (error) {
      this.showProgressError(error)
    } finally {
      this.setBusy(form, false)
      if (!this.progressErrorVisible && !keepDraftProgress) this.stopProgress()
    if (!this.progressErrorVisible && keepDraftProgress) {
      this.ensureProgressTimer()
      this.scrollDraftProgressIntoView()
    }
      if (wasPolling || this.stationActive()) this.startPolling()
    }
  }

  startProgress(message) {
    this.progressErrorVisible = false
    this.clientProgressTimedOut = false
    if (this.progressStopTimer) window.clearTimeout(this.progressStopTimer)
    if (this.syncPulseHideTimer) window.clearTimeout(this.syncPulseHideTimer)
    this.progressStopTimer = null
    this.syncPulseHideTimer = null
    this.element.classList.remove("comms-command-row--syncing")
    this.element.classList.add("comms-command-row--busy")
    this.element.classList.add("comms-command-row--draft-clicking")
    this.setDraftProgressActive(true)
    this.draftKeyAtProgressStart = this.currentDraftKey()
    if (this.hasProgressMessageTarget) this.progressMessageTarget.textContent = message || "Thumper composing"
    this.progressStartedAt = Date.now()
    this.element.querySelectorAll(".comms-command-draft-progress").forEach((node) => {
      node.dataset.thumperProgressStartedAt = new Date(this.progressStartedAt).toISOString()
    })
    this.tickProgress()
    if (this.hasProgressTarget) this.progressTarget.classList.remove("hidden")
    this.scrollDraftProgressIntoView()
    if (this.progressTimer) window.clearInterval(this.progressTimer)
    this.progressTimer = window.setInterval(() => this.tickProgress(), 1000)
    this.armProgressDeadline()
  }

  stopProgress() {
    if (this.progressTimer) window.clearInterval(this.progressTimer)
    this.progressTimer = null
    if (this.progressDeadlineTimer) window.clearTimeout(this.progressDeadlineTimer)
    this.progressDeadlineTimer = null
    const elapsed = this.progressStartedAt ? Date.now() - this.progressStartedAt : 0
    const hideProgress = () => {
      this.progressStopTimer = null
      this.progressStartedAt = null
      this.draftKeyAtProgressStart = null
      this.element.classList.remove("comms-command-row--busy")
      this.element.classList.remove("comms-command-row--draft-clicking")
      this.setDraftProgressActive(false)
      this.setProgressTimerText("00:00")
      this.hideLiveProgress()
    }

    if (elapsed > 0 && elapsed < 1400) {
      if (this.progressStopTimer) window.clearTimeout(this.progressStopTimer)
      this.progressStopTimer = window.setTimeout(hideProgress, 1400 - elapsed)
    } else {
      hideProgress()
    }
  }

  showProgressError(error) {
    this.progressErrorVisible = true
    this.element.classList.add("comms-command-row--busy")
    this.element.classList.add("comms-command-row--draft-clicking")
    this.setDraftProgressActive(true)
    if (this.hasProgressMessageTarget) {
      this.progressMessageTarget.textContent = "Thumper request paused. Overlay stayed open; try Generate Next Text again."
    }
    if (this.hasProgressTimerTarget) {
      this.progressTimerTarget.textContent = error?.message || "retry"
    }
    if (this.hasProgressTarget) {
      this.progressTarget.classList.remove("hidden")
    }

    if (this.progressErrorTimer) window.clearTimeout(this.progressErrorTimer)
    this.progressErrorTimer = window.setTimeout(() => {
      this.progressErrorVisible = false
      this.stopProgress()
    }, 4200)
  }

  startSyncPulse(message = "Thumper live sync") {
    if (this.progressStartedAt) return
    if (this.stationActive()) return
    if (this.syncPulseHideTimer) window.clearTimeout(this.syncPulseHideTimer)
    this.syncPulseHideTimer = null
    this.element.classList.add("comms-command-row--syncing")
    if (this.hasProgressMessageTarget) this.progressMessageTarget.textContent = message
    if (this.hasProgressTarget) this.progressTarget.classList.remove("hidden")
  }

  stopSyncPulse({ immediate = false } = {}) {
    if (this.progressStartedAt) return
    if (this.stationActive()) return
    const hidePulse = () => {
      this.syncPulseHideTimer = null
      this.element.classList.remove("comms-command-row--syncing")
      this.hideLiveProgress()
    }

    if (this.syncPulseHideTimer) window.clearTimeout(this.syncPulseHideTimer)
    if (immediate) {
      hidePulse()
    } else {
      this.syncPulseHideTimer = window.setTimeout(hidePulse, 650)
    }
  }

  hideLiveProgress() {
    this.element.classList.remove("comms-command-row--syncing")
    if (this.hasProgressTarget) this.progressTarget.classList.add("hidden")
  }

  setDraftProgressActive(active) {
    this.element.querySelectorAll(".comms-command-communicator--phone").forEach((node) => {
      node.classList.toggle("comms-command-communicator--drafting", active)
      if (active) {
        node.dataset.thumperDrafting = "true"
      } else {
        delete node.dataset.thumperDrafting
      }
    })

    this.element.querySelectorAll(".comms-command-draft-progress").forEach((node) => {
      node.classList.toggle("comms-command-draft-progress--active", active)
      node.classList.toggle("is-live", active)
      if (active) {
        node.dataset.thumperProgressActive = "true"
        node.setAttribute("aria-busy", "true")
        node.querySelectorAll(".comms-command-draft-progress-bar span").forEach((span) => {
          span.style.width = "62%"
          span.style.opacity = "1"
          span.style.animation = "commsLiveRun 0.92s linear infinite, commsRainbowShift 0.52s linear infinite"
        })
      } else {
        delete node.dataset.thumperProgressActive
        node.removeAttribute("aria-busy")
        node.querySelectorAll(".comms-command-draft-progress-bar span").forEach((span) => {
          span.style.width = ""
          span.style.opacity = ""
          span.style.animation = ""
        })
      }
    })
  }

  primeDraftProgress(source, message = "Thumper COMPOSING") {
    const row = source instanceof Element ? source.closest(".comms-command-row") : this.element
    const root = row || this.element
    this.progressErrorVisible = false
    this.clientProgressTimedOut = false
    this.progressStartedAt = Date.now()
    this.draftKeyAtProgressStart = this.currentDraftKey(root)
    root.classList.add("comms-command-row--busy", "comms-command-row--draft-clicking")
    root.querySelectorAll(".comms-command-communicator--phone").forEach((node) => {
      node.classList.add("comms-command-communicator--drafting")
      node.dataset.thumperDrafting = "true"
    })
    root.querySelectorAll(".comms-command-draft-progress").forEach((node) => {
      node.classList.add("comms-command-draft-progress--active", "is-live")
      node.dataset.thumperProgressActive = "true"
      node.dataset.thumperProgressStartedAt = new Date(this.progressStartedAt).toISOString()
      node.setAttribute("aria-busy", "true")
      node.querySelectorAll(".comms-command-draft-progress-bar span").forEach((span) => {
        span.style.width = "62%"
        span.style.opacity = "1"
        span.style.animation = "commsLiveRun 0.92s linear infinite, commsRainbowShift 0.52s linear infinite"
      })
    })
    root.querySelectorAll("[data-comms-station-target~='progressMessage'], .comms-command-draft-progress-active").forEach((node) => {
      if (node.classList.contains("comms-command-draft-progress-timer")) return
      node.textContent = message
    })
    this.setProgressTimerText("00:00")
    this.tickProgress()
    if (this.progressTimer) window.clearInterval(this.progressTimer)
    this.progressTimer = window.setInterval(() => this.tickProgress(), 1000)
    this.armProgressDeadline()
    this.scrollChatToBottom(root, { includeNewest: true, preferProgress: true })
  }

  scrollDraftProgressIntoView() {
    const progress = this.element.querySelector(".comms-command-communicator--phone .comms-command-draft-progress")
    const chatlog = this.chatlogFor(this.element)
    if (!progress || !chatlog) return

    const run = () => {
      chatlog.scrollTop = chatlog.scrollHeight
      progress.scrollIntoView?.({ block: "nearest", inline: "nearest" })
    }
    run()
    window.requestAnimationFrame(run)
    window.setTimeout(run, 80)
  }

  tickProgress() {
    if (!this.progressStartedAt) return

    const elapsed = Math.max(0, Math.floor((Date.now() - this.progressStartedAt) / 1000))
    const minutes = Math.floor(elapsed / 60).toString().padStart(2, "0")
    const seconds = (elapsed % 60).toString().padStart(2, "0")
    this.setProgressTimerText(`${minutes}:${seconds}`)
  }

  ensureProgressTimer() {
    if (!this.progressStartedAt) this.progressStartedAt = Date.now()
    this.setDraftProgressActive(true)
    this.tickProgress()
    if (this.progressTimer) window.clearInterval(this.progressTimer)
    this.progressTimer = window.setInterval(() => this.tickProgress(), 1000)
    this.armProgressDeadline()
  }

  armProgressDeadline() {
    if (this.progressDeadlineTimer) window.clearTimeout(this.progressDeadlineTimer)
    if (!this.progressStartedAt) return

    const remaining = CLIENT_DRAFT_TIMEOUT_MS - (Date.now() - this.progressStartedAt)
    if (remaining <= 0) {
      this.expireClientProgress()
      return
    }
    this.progressDeadlineTimer = window.setTimeout(() => this.expireClientProgress(), remaining)
  }

  expireClientProgress() {
    if (!this.progressStartedAt) return

    this.clientProgressTimedOut = true
    this.progressErrorVisible = false
    this.stopProgress()
    this.refreshSoon(0)
  }

  setProgressTimerText(text) {
    this.element.querySelectorAll("[data-comms-station-target~='progressTimer'], .comms-command-draft-progress-timer").forEach((node) => {
      node.textContent = text
    })
  }

  resumeDraftProgressTimerIfActive() {
    const progress = this.element.querySelector(".comms-command-draft-progress--active, .comms-command-draft-progress.is-live, .comms-command-draft-progress[data-autos-progress-active='true'], .comms-command-row--drafting .comms-command-draft-progress")
    if (!progress && !this.element.classList.contains("comms-command-row--drafting")) return

    this.progressStartedAt = this.progressStartedAtFrom(this.element)
    this.setDraftProgressActive(true)
    this.tickProgress()
    if (this.progressTimer) window.clearInterval(this.progressTimer)
    this.progressTimer = window.setInterval(() => this.tickProgress(), 1000)
  }

  progressLabelFor(form, submitter) {
    const text = `${submitter?.value || submitter?.textContent || ""} ${form.action || ""}`.toLowerCase()
    if (text.includes("autopilot")) return "Thumper starting autopilot"
    if (text.includes("reset") || text.includes("/sms/reset")) return "Thumper resetting conversation"
    if (text.includes("copilot") || text.includes("/sms/copilot")) return "COPILOT drafting next text"
    if (text.includes("generate") || text.includes("/sms/draft")) return "Thumper drafting next text"
    if (text.includes("shopify") || text.includes("link")) return "Thumper preparing checkout link"
    if (text.includes("send")) return "Thumper sending SMS and opening listener"
    return "Thumper composing"
  }

  async refresh() {
    if (!this.stationActive()) return
    if (this.refreshInFlight) return
    const scrollState = this.captureScrollState()
    const editing = this.isEditing()
    this.refreshInFlight = true
    this.startSyncPulse()

    try {
      const response = await fetch(this.liveUrl(), {
        credentials: "same-origin",
        cache: "no-store",
        headers: {
          "Accept": "text/html",
          "Cache-Control": "no-cache",
          "X-Requested-With": "XMLHttpRequest",
        },
      })

      if (!response.ok) return
      const html = await response.text()
      this.patchLiveSectionsFromHtml(html, { scrollState, scrollChatToEnd: false, force: editing })
    } catch (_) {
      // Polling is a soft live-update path. A missed poll should not disturb the operator.
    } finally {
      this.refreshInFlight = false
      this.stopSyncPulse()
    }
  }

  liveUrl() {
    try {
      const url = new URL(this.urlValue, window.location.origin)
      url.searchParams.set("_live_at", Date.now().toString())
      return url.toString()
    } catch (_) {
      return this.urlValue
    }
  }

  patchLiveSectionsFromHtml(html, { scrollState = null, scrollChatToEnd = false, force = false } = {}) {
    const next = new DOMParser().parseFromString(html, "text/html").getElementById(this.element.id)
    if (!next) return

    const nextVersion = next.dataset.commsStationVersionValue
    if (!force && !this.hasLazyStation() && nextVersion && nextVersion === this.versionValue) return
    const serverDrafting = this.nodeShowsDrafting(next)

    if ((this.hasLazyStation() || (this.phoneDetails()?.open && !this.isEditing())) && this.replacePhoneOverlay(next, { scrollState, scrollChatToEnd })) {
      this.element.className = next.className
      this.copyLiveSection(next, ".comms-command-icon-button--attn")
      if (nextVersion) {
        this.element.dataset.commsStationVersionValue = nextVersion
        this.versionValue = nextVersion
      }
      this.syncSmsWriterModel(this.pendingSmsWriterModel || this.currentSmsWriterModel())
      this.syncServerProgress(serverDrafting)
      this.startAttentionTimer()
      return
    }

    this.element.className = next.className
    this.copyLiveSection(next, ".comms-command-chatlog")
    this.copyLiveSection(next, ".comms-command-live-progress")
    this.copyLiveSection(next, ".comms-command-processing-strip")
    this.copyLiveSection(next, ".comms-command-location-strip")
    this.copyLiveSection(next, ".comms-command-phone-status")
    this.copyLiveSection(next, ".comms-command-callblock-banner")
    this.copyLiveSection(next, ".comms-command-card-status")
    this.copyLiveSection(next, ".comms-command-icon-button--attn")
    this.copyLiveSection(next, ".comms-command-discovery-strip")
    this.copyLiveSection(next, ".comms-command-draft-status")
    this.copyLiveSection(next, ".comms-command-draft-meta")
    this.copyFormValue(next, "textarea[name='sms_body']")
    this.copyFormValue(next, "textarea[name='sms_prompt']")

    if (nextVersion) {
      this.element.dataset.commsStationVersionValue = nextVersion
      this.versionValue = nextVersion
    }
    this.syncSmsWriterModel(this.pendingSmsWriterModel || this.currentSmsWriterModel())
    this.syncServerProgress(serverDrafting)
    this.startAttentionTimer()
    this.restoreScrollState(scrollState, { scrollChatToEnd, root: this.element, preferProgress: serverDrafting })
    if (serverDrafting && (!scrollState || scrollState.shouldStick)) this.scrollPhoneChatToEnd({ includeNewest: true })
  }

  startAttentionTimer() {
    this.stopAttentionTimer()
    const light = this.element.querySelector("[data-comms-attn-started-at]")
    if (!light) {
      this.setAttentionTimerText("00:00")
      return
    }

    const startedAt = Date.parse(light.dataset.commsAttnStartedAt || "")
    if (Number.isNaN(startedAt)) {
      this.setAttentionTimerText("00:00")
      return
    }

    const tick = () => {
      const elapsed = Math.max(0, Math.floor((Date.now() - startedAt) / 1000))
      const minutes = Math.floor(elapsed / 60).toString().padStart(2, "0")
      const seconds = (elapsed % 60).toString().padStart(2, "0")
      this.setAttentionTimerText(`${minutes}:${seconds}`)
    }

    tick()
    this.attentionTimer = window.setInterval(tick, 1000)
  }

  stopAttentionTimer() {
    if (this.attentionTimer) window.clearInterval(this.attentionTimer)
    this.attentionTimer = null
  }

  setAttentionTimerText(text) {
    this.element.querySelectorAll("[data-comms-attn-timer], .comms-command-attn-timer").forEach((node) => {
      node.textContent = text
    })
  }

  syncServerProgress(serverDrafting) {
    if (this.progressErrorVisible) return

    if (serverDrafting) {
      if (this.clientProgressTimedOut) {
        this.setDraftProgressActive(false)
        this.setProgressTimerText("00:00")
        return
      }
      if (!this.progressStartedAt) this.progressStartedAt = this.progressStartedAtFrom(this.element)
      this.ensureProgressTimer()
      return
    }

    this.clientProgressTimedOut = false

    if (this.progressStartedAt) {
      this.stopProgress()
    } else {
      this.setDraftProgressActive(false)
      this.setProgressTimerText("00:00")
    }
  }

  shouldKeepClientProgress() {
    if (!this.progressStartedAt) return false
    if (Date.now() - this.progressStartedAt > 3 * 60 * 1000) return false

    const currentKey = this.currentDraftKey()
    if (this.draftKeyAtProgressStart && currentKey && this.draftKeyAtProgressStart !== currentKey) return false

    return true
  }

  progressStartedAtFrom(root = this.element) {
    const progress = root.querySelector(".comms-command-draft-progress--active, .comms-command-draft-progress.is-live, .comms-command-draft-progress[data-autos-progress-active='true'], .comms-command-draft-progress")
    const startedAt = Date.parse(progress?.dataset?.thumperProgressStartedAt || "")
    return Number.isNaN(startedAt) ? Date.now() : startedAt
  }

  htmlShowsDrafting(html) {
    const next = new DOMParser().parseFromString(html, "text/html").getElementById(this.element.id)
    return this.nodeShowsDrafting(next)
  }

  htmlDraftKeyChanged(html) {
    if (!this.draftKeyAtProgressStart) return false

    const next = new DOMParser().parseFromString(html, "text/html").getElementById(this.element.id)
    const nextKey = this.currentDraftKey(next)
    return !!nextKey && nextKey !== this.draftKeyAtProgressStart
  }

  currentDraftKey(root = this.element) {
    const field = root?.querySelector?.("textarea[name='sms_body']")
    if (field instanceof HTMLTextAreaElement || field instanceof HTMLInputElement) {
      return field.dataset?.thumperDraftKey || field.value || ""
    }

    return ""
  }

  applyBotBridgeStopText(event) {
    const checkbox = event?.target
    if (!(checkbox instanceof HTMLInputElement) || !checkbox.checked) return

    const body = checkbox.dataset.botBridgeStopText || ""
    const root = checkbox.closest(".comms-command-communicator") || this.element
    const field = root.querySelector("textarea[name='sms_body']")
    if (!(field instanceof HTMLTextAreaElement || field instanceof HTMLInputElement) || body.length === 0) return

    field.value = body
    field.dataset.thumperDraftKey = body
    field.dispatchEvent(new Event("input", { bubbles: true }))
    field.dispatchEvent(new Event("change", { bubbles: true }))
  }

  nodeShowsDrafting(node) {
    if (!(node instanceof Element)) return false
    return node.classList.contains("comms-command-row--drafting") ||
      !!node.querySelector(".comms-command-row--drafting, .comms-command-draft-progress--active, .comms-command-draft-progress.is-live, .comms-command-draft-progress[data-autos-progress-active='true']")
  }

  copyLiveSection(next, selector) {
    const currentNode = this.element.querySelector(selector)
    const nextNode = next.querySelector(selector)
    if (!currentNode || !nextNode) return

    currentNode.replaceWith(nextNode)
  }

  copyFormValue(next, selector) {
    const currentNode = this.element.querySelector(selector)
    const nextNode = next.querySelector(selector)
    const currentEditable = currentNode instanceof HTMLTextAreaElement || currentNode instanceof HTMLInputElement
    const nextEditable = nextNode instanceof HTMLTextAreaElement || nextNode instanceof HTMLInputElement
    if (!currentEditable || !nextEditable) return
    if (currentNode === document.activeElement && currentNode.value !== currentNode.defaultValue) return

    currentNode.value = nextNode.value
    currentNode.defaultValue = nextNode.value
  }

  async copyText(event) {
    const button = event.target instanceof Element ? event.target.closest("[data-copy-text], [data-copy-thread-selector]") : null
    if (!button) return

    event.preventDefault()
    event.stopPropagation()
    event.stopImmediatePropagation?.()

    const text = this.copyTextForButton(button)
    if (!text) return

    try {
      await this.writeClipboard(text)
      this.flashCopyButton(button)
    } catch (error) {
      console.warn("Could not copy SMS text", error)
    }
  }

  copyTextForButton(button) {
    const directText = button.dataset.copyText
    if (directText) return directText

    const selector = button.dataset.copyThreadSelector
    if (!selector) return ""

    const root = button.closest(".comms-command-square--history") || this.element
    const thread = root.querySelector(selector)
    if (!thread) return ""

    return Array.from(thread.querySelectorAll("[data-copy-line]"))
      .map((node) => node.dataset.copyLine || node.textContent.trim())
      .filter(Boolean)
      .join("\n\n")
  }

  async writeClipboard(text) {
    if (navigator.clipboard?.writeText && window.isSecureContext) {
      await navigator.clipboard.writeText(text)
      return
    }

    const field = document.createElement("textarea")
    field.value = text
    field.setAttribute("readonly", "readonly")
    field.style.position = "fixed"
    field.style.left = "-9999px"
    document.body.appendChild(field)
    field.select()
    document.execCommand("copy")
    field.remove()
  }

  flashCopyButton(button) {
    const original = button.dataset.copyOriginalLabel || button.textContent
    button.dataset.copyOriginalLabel = original
    button.textContent = "COPIED"
    window.clearTimeout(button._copyResetTimer)
    button._copyResetTimer = window.setTimeout(() => {
      button.textContent = button.dataset.copyOriginalLabel || original
    }, 1200)
  }

  replaceFromHtml(html, { force = false, keepPhoneOpen = true, openIndex = null, preservePhoneOverlay = false, scrollState = null, scrollChatToEnd = false } = {}) {
    const next = new DOMParser().parseFromString(html, "text/html").getElementById(this.element.id)
    if (!next) return

    const nextVersion = next.dataset.commsStationVersionValue
    if (!force && !this.hasLazyStation() && nextVersion && nextVersion === this.versionValue) return

    if (preservePhoneOverlay && this.replacePhoneOverlay(next, { openIndex, scrollState, scrollChatToEnd })) {
      this.element.className = next.className
      this.copyLiveSection(next, ".comms-command-icon-button--attn")
      this.copyLiveSection(next, ".comms-command-callblock-banner")
      if (nextVersion) {
        this.element.dataset.commsStationVersionValue = nextVersion
        this.versionValue = nextVersion
      }
      this.syncSmsWriterModel(this.pendingSmsWriterModel || this.currentSmsWriterModel())
      this.startAttentionTimer()
      return
    }

    if (openIndex !== null) {
      const details = next.querySelectorAll(".comms-command-details")[openIndex]
      if (details instanceof HTMLDetailsElement) details.open = true
    } else if (keepPhoneOpen) {
      const details = next.querySelector(".comms-command-details")
      if (details instanceof HTMLDetailsElement) details.open = true
    }

    this.element.replaceWith(next)
    this.syncSmsWriterModel(this.pendingSmsWriterModel || this.currentSmsWriterModel(next), next)
    this.restoreScrollState(scrollState, { scrollChatToEnd, root: next })
  }

  replacePhoneOverlay(next, { openIndex = null, scrollState = null, scrollChatToEnd = false } = {}) {
    const currentDetails = openIndex !== null ? this.element.querySelectorAll(".comms-command-details")[openIndex] : this.phoneDetails()
    const nextDetails = openIndex !== null ? next.querySelectorAll(".comms-command-details")[openIndex] : this.nextPhoneDetails(next)
    if (!(currentDetails instanceof HTMLDetailsElement) || !(nextDetails instanceof HTMLDetailsElement)) return false

    const currentPhone = currentDetails.querySelector(".comms-command-communicator--phone")
    const nextPhone = nextDetails.querySelector(".comms-command-communicator--phone")
    if (!nextPhone) return false

    if (!currentPhone) {
      const summary = currentDetails.querySelector("summary")
      currentDetails.open = true
      if (summary) {
        summary.insertAdjacentElement("afterend", nextPhone)
      } else {
        currentDetails.appendChild(nextPhone)
      }
      const serverDrafting = this.nodeShowsDrafting(currentDetails)
      this.restoreScrollState(scrollState, { scrollChatToEnd: true, root: currentDetails, preferProgress: serverDrafting })
      this.scrollPhoneChatToEnd({ includeNewest: true, preferProgress: serverDrafting })
      return true
    }

    nextDetails.open = true
    currentPhone.replaceWith(nextPhone)
    currentDetails.open = true
    const serverDrafting = this.nodeShowsDrafting(currentDetails)
    this.syncSmsWriterModel(this.pendingSmsWriterModel || this.currentSmsWriterModel(currentDetails), currentDetails)
    this.restoreScrollState(scrollState, { scrollChatToEnd, root: currentDetails, preferProgress: serverDrafting })
    if (scrollChatToEnd) this.scrollPhoneChatToEnd({ includeNewest: true, preferProgress: serverDrafting })
    return true
  }

  captureScrollState() {
    const chatlog = this.element.querySelector(".comms-command-communicator--phone .comms-command-chatlog")
    if (!chatlog) return null

    return {
      top: chatlog.scrollTop,
      bottomGap: chatlog.scrollHeight - chatlog.scrollTop - chatlog.clientHeight,
      shouldStick: (chatlog.scrollHeight - chatlog.scrollTop - chatlog.clientHeight) <= 80,
    }
  }

  restoreScrollState(scrollState, { scrollChatToEnd = false, root = this.element, preferProgress = false } = {}) {
    const chatlog = this.chatlogFor(root)
    if (!chatlog) return

    if (!scrollState || scrollChatToEnd || scrollState.shouldStick) {
      this.scrollChatToBottom(root, { includeNewest: true, preferProgress })
      return
    }

    const restoreTop = () => {
      chatlog.scrollTop = Math.max(0, Math.min(scrollState.top || 0, chatlog.scrollHeight - chatlog.clientHeight))
    }
    restoreTop()
    window.requestAnimationFrame(restoreTop)
    window.setTimeout(restoreTop, 80)
    window.setTimeout(restoreTop, 220)
  }

  scrollPhoneChatToEnd({ includeNewest = true, preferProgress = false } = {}) {
    this.scrollChatToBottom(this.element, { includeNewest, preferProgress })
  }

  chatlogFor(root = this.element) {
    return root.querySelector(".comms-command-communicator--phone .comms-command-chatlog")
  }

  scrollChatToBottom(root = this.element, { includeNewest = true, preferProgress = false } = {}) {
    const run = () => this.forceChatBottom(root, { includeNewest, preferProgress })
    run()
    window.requestAnimationFrame(run)
    window.requestAnimationFrame(() => window.requestAnimationFrame(run))
    window.setTimeout(run, 60)
    window.setTimeout(run, 160)
    window.setTimeout(run, 360)
    window.setTimeout(run, 720)
    window.setTimeout(run, 1200)
  }

forceChatBottom(root = this.element, { includeNewest = true, preferProgress = false } = {}) {
  const chatlog = this.chatlogFor(root)
  if (!chatlog) return

  if (includeNewest) {
    const latestEnd = chatlog.querySelector(".comms-command-chat-latest-end")
    const latestText = Array.from(chatlog.querySelectorAll(".comms-command-bubble, .comms-command-empty")).at(-1)
    const activeProgress = chatlog.querySelector(".comms-command-draft-progress--active, .comms-command-draft-progress.is-live, .comms-command-draft-progress[data-autos-progress-active='true']")
    const target = latestEnd || latestText || chatlog.querySelector(".comms-command-chat-end") || activeProgress

    if (target?.scrollIntoView) {
      target.scrollIntoView({ block: "end", inline: "nearest" })
      const chatRect = chatlog.getBoundingClientRect()
      const targetRect = target.getBoundingClientRect()
      const bottomDelta = targetRect.bottom - chatRect.bottom
      if (Math.abs(bottomDelta) > 1) chatlog.scrollTop += bottomDelta
      return
    }
  }

  chatlog.scrollTop = chatlog.scrollHeight
  chatlog.scrollTo?.({ top: chatlog.scrollHeight, behavior: "auto" })
  chatlog.scrollTop = 999999
}

  formData(form, submitter) {
    try {
      return new FormData(form, submitter)
    } catch (_) {
      const data = new FormData(form)
      if (submitter?.name) data.append(submitter.name, submitter.value)
      return data
    }
  }

  setBusy(form, busy) {
    form.toggleAttribute("aria-busy", busy)
    form.querySelectorAll("button, input[type='submit']").forEach((button) => {
      button.toggleAttribute("disabled", busy)
    })
  }

  isSmsDraftForm(form) {
    return form instanceof HTMLFormElement && /\/sms\/(?:draft|reset|copilot)(?:$|\?)/.test(form.action || "")
  }

  isEditing() {
    const active = document.activeElement
    return active instanceof HTMLElement &&
      this.element.contains(active) &&
      active.matches("input, textarea, select, [contenteditable='true']")
  }

  phoneDetails() {
    return Array.from(this.element.querySelectorAll(".comms-command-details")).find((details) => {
      return details instanceof HTMLDetailsElement && details.querySelector(".comms-command-communicator--phone")
    })
  }

  nextPhoneDetails(element) {
    return Array.from(element.querySelectorAll(".comms-command-details")).find((details) => {
      return details instanceof HTMLDetailsElement && details.querySelector(".comms-command-communicator--phone")
    })
  }

  hasLazyStation() {
    return !!this.element.querySelector(".comms-command-communicator[data-comms-lazy-station='true']")
  }

  detailsIndex(details) {
    if (!(details instanceof HTMLDetailsElement)) return null
    return Array.from(this.element.querySelectorAll(".comms-command-details")).indexOf(details)
  }
}
