import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["button", "idle", "working", "seconds"]
  static values = {
    audience: { type: String, default: "report" },
    dealId: Number,
    pollInterval: { type: Number, default: 5000 },
    reportCount: Number,
    statusUrl: String
  }

  connect() {
    this.elapsed = 0
    this.timer = null
    this.poller = null
    this.submitting = null
    this.pending = this.readPending()

    if (!this.pending && this.isProcessingBadge()) {
      this.pending = {
        audience: this.normalizedAudience(),
        expectedReportCount: Math.max(1, this.reportCountValue || 1),
        startedAt: Date.now(),
        serverRendered: true
      }
    }

    if (this.pending) {
      this.elapsed = Math.max(0, Math.floor((Date.now() - Number(this.pending.startedAt || Date.now())) / 1000))
      this.showWorkingState()
      this.startClock()
      this.startPoller()
      this.pollStatus()
    }
  }

  start() {
    this.elapsed = 0
    this.submitting = {
      audience: this.normalizedAudience(),
      expectedReportCount: this.currentReportCount() + 1,
      startedAt: Date.now()
    }
    this.showWorkingState()
    this.startClock()
  }

  submitted(event) {
    if (event?.detail && event.detail.success === false) {
      this.clearPending()
      this.clearWorkingState("Report request did not reach WIZWIKI. Try RUN again.")
      return
    }

    if (!this.pending) {
      this.elapsed = 0
      this.pending = this.submitting || {
        audience: this.normalizedAudience(),
        expectedReportCount: this.currentReportCount() + 1,
        startedAt: Date.now()
      }
      this.writePending(this.pending)
    }

    this.submitting = null
    this.showWorkingState()
    this.startClock()
    this.startPoller()
    window.setTimeout(() => this.refreshFrames(), 450)
  }

  disconnect() {
    if (this.timer) window.clearInterval(this.timer)
    if (this.poller) window.clearInterval(this.poller)
  }

  showWorkingState() {
    this.element.classList.add("report-timer-active")
    this.bumpCard()
    this.updateProcessingBayFeedback()
    this.closeOpenDetails()

    if (this.hasButtonTarget) {
      this.buttonTarget.disabled = true
      this.buttonTarget.classList.add("am-report-button--working")
    }
    if (this.hasIdleTarget) this.idleTarget.hidden = true
    if (this.hasWorkingTarget) this.workingTarget.hidden = false
  }

  bumpCard() {
    const card = this.element.closest("[data-deal-card]")
    if (!card) return

    card.classList.add("deal-card--report-pending")
    card.dataset.reportPending = this.audienceLabel()
    card.dataset.reportPendingSeconds = `${this.elapsed}s`
  }

  updateProcessingBayFeedback() {
    this.updateCardTimer()

    const feedback = document.getElementById("processing-bay-live-feedback")
    if (!feedback || !(this.pending || this.submitting)) return

    feedback.hidden = false
    const status = this.pending ? "Alice handoff running" : "sending request to WIZWIKI"
    feedback.textContent = `${this.audienceLabel()} report queued. ${status} // ${this.elapsed}s`
    feedback.classList.add("processing-bay-live-feedback--active")
  }

  updateCardTimer() {
    const card = this.element.closest("[data-deal-card]")
    if (!card || !card.classList.contains("deal-card--report-pending")) return

    card.dataset.reportPendingSeconds = `${this.elapsed}s`
  }

  closeOpenDetails() {
    this.element.closest("details")?.removeAttribute("open")
  }

  startClock() {
    if (this.timer) window.clearInterval(this.timer)
    this.tick()
    this.timer = window.setInterval(() => this.tick(), 1000)
  }

  startPoller() {
    if (this.poller) return
    this.poller = window.setInterval(() => this.pollStatus(), this.pollIntervalValue)
  }

  tick() {
    if (this.hasSecondsTarget) this.secondsTarget.textContent = `${this.elapsed}s`
    this.updateProcessingBayFeedback()
    this.elapsed += 1
  }

  async pollStatus() {
    if (!this.statusUrlValue || !this.pending) return

    try {
      const response = await fetch(this.statusUrlValue, {
        headers: { Accept: "application/json" },
        credentials: "same-origin"
      })
      if (!response.ok) return

      const data = await response.json()
      const status = this.statusForAudience(data)
      const reportCount = Number(status.report_count || 0)
      const active = Number(status.active_report_count || 0)
      const expected = Number(this.pending.expectedReportCount || this.pending.expectedCompletedReportCount || 0)
      const latestStatus = String(status.latest_report?.status || "")
      const newReportExists = expected > 0 && reportCount >= expected
      const failed = newReportExists && active === 0 && latestStatus === "failed"
      const canceled = newReportExists && active === 0 && latestStatus === "canceled"
      const serverFinishedWithoutActiveJob = active === 0 && ["failed", "canceled", "archived", "ready", "canva_kit_ready"].includes(latestStatus)
      const pendingAge = Date.now() - Number(this.pending.startedAt || 0)
      const serverIdleWithoutNewReport = expected > 0 && reportCount < expected && active === 0 && pendingAge > 45 * 1000
      const expired = pendingAge > 20 * 60 * 1000

      if ((newReportExists && active === 0) || failed || canceled || serverFinishedWithoutActiveJob || serverIdleWithoutNewReport || expired) {
        this.clearPending()
        this.clearWorkingState(canceled ? "Report run canceled." : (latestStatus === "failed" ? "Report failed. RUN reset." : (serverIdleWithoutNewReport ? "No active report job on WIZWIKI. RUN reset." : null)))
        this.refreshPage()
      }
    } catch (_) {
      // Keep polling. A transient tunnel/browser failure should not reset the pending state.
    }
  }

  refreshFrames(delay = 0) {
    window.setTimeout(() => {
      const url = `${window.location.pathname}${window.location.search}`
      const frameIds = ["deal_queue_stats", "deal_queue_processing_bay", "deal_queue_results"]
      const anchor = this.captureViewportAnchor()
      let refreshed = false
      let restoreQueued = false

      const queueRestore = () => {
        if (restoreQueued) return
        restoreQueued = true
        window.requestAnimationFrame(() => {
          window.requestAnimationFrame(() => this.restoreViewportAnchor(anchor))
        })
      }

      frameIds.forEach((id) => {
        const frame = document.getElementById(id)
        if (!frame || frame.tagName !== "TURBO-FRAME") return

        refreshed = true
        frame.addEventListener("turbo:frame-load", queueRestore, { once: true })
        frame.src = url
        frame.reload?.()
      })

      if (refreshed) window.setTimeout(queueRestore, 1200)
    }, delay)
  }

  refreshPage() {
    this.refreshFrames(0)
  }

  captureViewportAnchor() {
    const card = this.element.closest("[data-deal-card]")
    if (card?.id) {
      return {
        cardId: card.id,
        cardTop: card.getBoundingClientRect().top,
        scrollX: window.scrollX,
        scrollY: window.scrollY
      }
    }

    return {
      scrollX: window.scrollX,
      scrollY: window.scrollY
    }
  }

  restoreViewportAnchor(anchor) {
    if (!anchor) return

    const card = anchor.cardId ? document.getElementById(anchor.cardId) : null
    if (card) {
      const delta = card.getBoundingClientRect().top - Number(anchor.cardTop || 0)
      if (Math.abs(delta) > 1) window.scrollBy(0, delta)
      return
    }

    window.scrollTo(Number(anchor.scrollX || 0), Number(anchor.scrollY || 0))
  }

  isProcessingBadge() {
    return this.element.classList.contains("deal-card-processing-badge")
  }

  audienceLabel() {
    const audience = this.normalizedAudience()
    if (audience === "am") return "ACCOUNT REPORT"
    if (audience === "copy_maker") return "COPYWRITER"
    return "CLIENT REPORT"
  }

  normalizedAudience() {
    const selected = this.element.querySelector("[name='report_audience']")?.value || this.audienceValue
    return ["am", "copy_maker"].includes(selected) ? selected : "client"
  }

  currentReportCount() {
    return Number(this.element.dataset.reportTimerReportCountValue || this.reportCountValue || 0)
  }

  statusForAudience(data) {
    return data?.audiences?.[this.normalizedAudience()] || data || {}
  }

  storageKey() {
    return this.hasDealIdValue ? `wizwiki:report-pending:${this.dealIdValue}:${this.normalizedAudience()}` : null
  }

  legacyStorageKey() {
    return this.hasDealIdValue ? `wizwiki:report-pending:${this.dealIdValue}` : null
  }

  readPending() {
    const key = this.storageKey()
    if (!key) return null

    try {
      const raw = window.sessionStorage?.getItem(key)
      return raw ? JSON.parse(raw) : null
    } catch (_) {
      return null
    }
  }

  writePending(value) {
    const key = this.storageKey()
    if (!key) return

    try {
      window.sessionStorage?.setItem(key, JSON.stringify(value))
    } catch (_) {
      // Session storage is a convenience for post-submit polling, not a hard requirement.
    }
  }

  clearPending() {
    const key = this.storageKey()
    this.pending = null
    this.submitting = null

    try {
      if (key) window.sessionStorage?.removeItem(key)
      const legacyKey = this.legacyStorageKey()
      if (legacyKey) window.sessionStorage?.removeItem(legacyKey)
      this.clearAudiencePendingKeys()
    } catch (_) {
    }
  }

  clearAudiencePendingKeys() {
    if (!this.hasDealIdValue) return

    ;["client", "am", "copy_maker"].forEach((audience) => {
      window.sessionStorage?.removeItem(`wizwiki:report-pending:${this.dealIdValue}:${audience}`)
    })
  }

  clearWorkingState(message = null) {
    if (this.timer) window.clearInterval(this.timer)
    this.timer = null

    this.element.classList.remove("report-timer-active")
    if (this.hasButtonTarget) {
      this.buttonTarget.disabled = false
      this.buttonTarget.classList.remove("am-report-button--working")
    }
    if (this.hasIdleTarget) this.idleTarget.hidden = false
    if (this.hasWorkingTarget) this.workingTarget.hidden = true

    const card = this.element.closest("[data-deal-card]")
    if (card) {
      card.classList.remove("deal-card--report-pending")
      delete card.dataset.reportPending
      delete card.dataset.reportPendingSeconds
    }

    const feedback = document.getElementById("processing-bay-live-feedback")
    if (feedback && message) {
      feedback.hidden = false
      feedback.textContent = message
      feedback.classList.remove("processing-bay-live-feedback--active")
    } else if (feedback) {
      feedback.hidden = true
      feedback.textContent = ""
      feedback.classList.remove("processing-bay-live-feedback--active")
    }
  }
}
