import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static values = {
    interval: { type: Number, default: 5000 },
    url: String,
    version: String,
    versionUrl: String,
    changeToken: String,
  }

  connect() {
    this.refresh = this.refresh.bind(this)
    this.tickTimers = this.tickTimers.bind(this)
    this.refreshInFlight = false
    this.startPolling()
    this.startTimerClock()
  }

  disconnect() {
    this.stopPolling()
    this.stopTimerClock()
  }

  startPolling() {
    if (this.poller) return
    this.poller = window.setInterval(this.refresh, this.intervalValue)
  }

  stopPolling() {
    if (!this.poller) return
    window.clearInterval(this.poller)
    this.poller = null
  }

  startTimerClock() {
    if (this.timerClock) return
    this.tickTimers()
    this.timerClock = window.setInterval(this.tickTimers, 1000)
  }

  stopTimerClock() {
    if (!this.timerClock) return
    window.clearInterval(this.timerClock)
    this.timerClock = null
  }

  tickTimers() {
    this.tickReportTimers()

    this.element.querySelectorAll("[data-follow-up-timer]").forEach((timer) => {
      const state = timer.dataset.followUpTimerState
      const dueAt = Date.parse(timer.dataset.followUpTimerDueAt || "")
      const label = timer.querySelector("[data-follow-up-timer-label]")
      if (!label || !Number.isFinite(dueAt)) return
      if (!["countdown", "outside_window", "capped"].includes(state)) return

      const seconds = Math.max(0, Math.floor((dueAt - Date.now()) / 1000))
      if (state === "capped" && !timer.dataset.followUpTimerBaseLabel) {
        timer.dataset.followUpTimerBaseLabel = label.textContent.trim() || "DAILY CAP"
      }

      if (seconds <= 0) {
        label.textContent = timer.dataset.followUpTimerDueLabel || "STALE NOW"
        timer.classList.add("comms-command-stale-timer--due")
        return
      }

      const prefix = timer.dataset.followUpTimerPrefix || "STALE IN"
      if (state === "capped") {
        label.textContent = `${timer.dataset.followUpTimerBaseLabel} // ${prefix} ${this.formatDuration(seconds)}`
      } else {
        label.textContent = `${prefix} ${this.formatDuration(seconds)}`
      }
      timer.classList.remove("comms-command-stale-timer--due")
    })
  }

  tickReportTimers() {
    this.element.querySelectorAll("[data-report-card-timer]").forEach((timer) => {
      const startedAt = Date.parse(timer.dataset.reportCardTimerStartedAt || "")
      const label = timer.querySelector("[data-report-card-timer-label]")
      if (!label || !Number.isFinite(startedAt)) return

      const seconds = Math.max(0, Math.floor((Date.now() - startedAt) / 1000))
      const audience = timer.dataset.reportCardTimerLabel || "RPT"
      const status = (timer.dataset.reportCardTimerStatus || "running").replaceAll("_", " ")
      label.textContent = `${audience} ${status} // ${this.formatDuration(seconds)}`
    })
  }

  formatDuration(seconds) {
    const days = Math.floor(seconds / 86400)
    const hours = Math.floor((seconds % 86400) / 3600)
    const minutes = Math.floor((seconds % 3600) / 60)
    const secs = seconds % 60

    if (days > 0) return `${days}d ${hours.toString().padStart(2, "0")}h`
    if (hours > 0) return `${hours}h ${minutes.toString().padStart(2, "0")}m`
    return `${minutes}m ${secs.toString().padStart(2, "0")}s`
  }

  async refresh() {
    if (document.hidden || this.isEditing() || this.hasOpenOverlay()) return
    if (this.refreshInFlight) return

    this.refreshInFlight = true

    try {
      const nextChangeToken = await this.fetchChangeToken()
      if (nextChangeToken && this.hasChangeTokenValue && nextChangeToken === this.changeTokenValue) return

      const response = await fetch(this.refreshUrl(), {
        credentials: "same-origin",
        headers: {
          "Accept": "text/html",
          "X-Requested-With": "XMLHttpRequest",
        },
      })

      if (!response.ok) return

      const next = new DOMParser()
        .parseFromString(await response.text(), "text/html")
        .querySelector(".comms-command-board")

      if (!next) return

      if (nextChangeToken) this.changeTokenValue = nextChangeToken
      const nextVersion = next.dataset.commsBoardVersionValue
      if (nextVersion && nextVersion === this.versionValue) return

      this.element.replaceWith(next)
    } catch (_) {
      // Soft live-update path. The operator can keep working if one poll misses.
    } finally {
      this.refreshInFlight = false
    }
  }

  refreshUrl() {
    const url = new URL(this.urlValue, window.location.origin)
    url.searchParams.set("board_refresh", "1")
    return url.toString()
  }

  async fetchChangeToken() {
    if (!this.hasVersionUrlValue) return null

    try {
      const response = await fetch(this.versionUrlValue, {
        credentials: "same-origin",
        cache: "no-store",
        headers: {
          "Accept": "application/json",
          "X-Requested-With": "XMLHttpRequest",
        },
      })
      if (!response.ok) return null

      const payload = await response.json()
      return typeof payload.version === "string" && payload.version ? payload.version : null
    } catch (_) {
      return null
    }
  }

  hasOpenOverlay() {
    return !!this.element.querySelector(".comms-command-details[open]")
  }

  isEditing() {
    const active = document.activeElement
    return active instanceof HTMLElement &&
      this.element.contains(active) &&
      active.matches("input, textarea, select, [contenteditable='true']")
  }
}
