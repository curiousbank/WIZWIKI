import { Controller } from "@hotwired/stimulus"
import { Turbo } from "@hotwired/turbo-rails"

export default class extends Controller {
  static values = {
    url: String,
    interval: { type: Number, default: 4000 }
  }

  connect() {
    this.refresh = this.refresh.bind(this)
    this.handleExternalRefresh = this.handleExternalRefresh.bind(this)
    this.updateProcessingTimers = this.updateProcessingTimers.bind(this)
    this.refreshUntil = 0
    window.addEventListener("autos:ask-refresh", this.handleExternalRefresh)
    this.refresh()
    this.timer = window.setInterval(this.refresh, this.intervalValue)
    this.processingTimer = window.setInterval(this.updateProcessingTimers, 1000)
    this.updateProcessingTimers()
  }

  disconnect() {
    window.removeEventListener("autos:ask-refresh", this.handleExternalRefresh)
    if (this.timer) window.clearInterval(this.timer)
    if (this.processingTimer) window.clearInterval(this.processingTimer)
  }

  async refresh() {
    if (!this.hasUrlValue || document.hidden) return
    if (!this.hasPendingQuestion() && Date.now() >= this.refreshUntil) return

    try {
      const response = await fetch(this.urlValue, {
        headers: {
          "Accept": "text/vnd.turbo-stream.html",
          "X-Requested-With": "XMLHttpRequest"
        },
        credentials: "same-origin"
      })
      if (!response.ok) return

      Turbo.renderStreamMessage(await response.text())
      window.setTimeout(this.updateProcessingTimers, 0)
    } catch (_error) {
      // WebSocket already failed on this path for some clients; polling is a best-effort fallback.
    }
  }

  hasPendingQuestion() {
    return Boolean(this.element.querySelector("[data-autos-question-pending=\"true\"]"))
  }

  handleExternalRefresh() {
    this.refreshUntil = Date.now() + 120000
    this.refresh()
  }

  updateProcessingTimers() {
    this.element.querySelectorAll("[data-wizwiki-processing-since]").forEach((node) => {
      const startedAt = Date.parse(node.dataset.wizwikiProcessingSince || "")
      if (Number.isNaN(startedAt)) return

      const elapsedSeconds = Math.max(0, Math.floor((Date.now() - startedAt) / 1000))
      const timer = node.querySelector("[data-wizwiki-processing-timer]")
      const bar = node.querySelector("[data-wizwiki-processing-bar]")
      if (timer) timer.textContent = this.formatDuration(elapsedSeconds)
      if (bar) bar.style.width = `${Math.min(96, 14 + elapsedSeconds * 2.4)}%`
    })
  }

  formatDuration(seconds) {
    const minutes = Math.floor(seconds / 60).toString().padStart(2, "0")
    const remainder = Math.floor(seconds % 60).toString().padStart(2, "0")
    return `${minutes}:${remainder}`
  }
}
