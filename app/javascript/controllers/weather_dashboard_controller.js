import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = [
    "riskMaxInput",
    "riskMaxLabel"
  ]

  static values = {
    interval: { type: Number, default: 20000 }
  }

  connect() {
    this.refresh = this.refresh.bind(this)
    this.tickTimeouts = this.tickTimeouts.bind(this)
    this.refreshInFlight = false
    this.tickTimeouts()
    this.syncRiskLabels()
    this.clockTimer = window.setInterval(this.tickTimeouts, 1000)
    this.refreshTimer = window.setInterval(this.refresh, this.intervalValue)
  }

  disconnect() {
    if (this.clockTimer) window.clearInterval(this.clockTimer)
    if (this.refreshTimer) window.clearInterval(this.refreshTimer)
  }

  refresh() {
    if (document.hidden || this.refreshInFlight) return

    const activeElement = document.activeElement
    if (activeElement && this.element.contains(activeElement) && ["INPUT", "SELECT", "TEXTAREA"].includes(activeElement.tagName)) return

    const frame = this.frameElement()
    if (!frame) return

    this.refreshInFlight = true
    const timeout = window.setTimeout(() => {
      this.refreshInFlight = false
    }, 15000)

    frame.addEventListener("turbo:frame-load", () => {
      window.clearTimeout(timeout)
      this.refreshInFlight = false
    }, { once: true })

    const url = new URL(window.location.href)
    url.searchParams.set("weather_live_refresh", String(Date.now()))
    frame.src = url.toString()
  }

  tickTimeouts() {
    const now = Date.now()
    this.element.querySelectorAll("[data-weather-timeout-at]").forEach((node) => {
      const closeAt = Date.parse(node.dataset.weatherTimeoutAt || "")
      if (!Number.isFinite(closeAt)) return

      const compact = node.dataset.weatherTimeoutCompact === "true"
      const delta = closeAt - now
      if (delta > 0) {
        node.textContent = compact ? this.compactDuration(delta) : `${this.compactDuration(delta)} left`
      } else {
        node.textContent = compact ? "closed" : `closed ${this.compactDuration(Math.abs(delta))} ago`
      }
    })
  }

  riskChanged() {
    this.syncRiskLabels()
  }

  syncRiskLabels() {
    if (this.hasRiskMaxInputTarget) {
      this.syncRiskDisplay("riskMaxLabel", "[data-risk-max-display]", this.riskMaxInputTarget.value)
    }
  }

  syncRiskDisplay(targetName, selector, value) {
    const display = this.money(value)
    const stimulusTargets = this[`${targetName}Targets`] || []
    stimulusTargets.forEach((target) => {
      target.textContent = display
    })
    this.element.querySelectorAll(selector).forEach((target) => {
      target.textContent = display
    })
  }

  frameElement() {
    if (this.element instanceof HTMLElement && this.element.tagName === "TURBO-FRAME") return this.element
    return this.element.closest("turbo-frame") || document.getElementById("weather_probability_lab")
  }

  compactDuration(ms) {
    const totalSeconds = Math.max(Math.floor(ms / 1000), 0)
    const days = Math.floor(totalSeconds / 86400)
    const hours = Math.floor((totalSeconds % 86400) / 3600)
    const minutes = Math.floor((totalSeconds % 3600) / 60)
    const seconds = totalSeconds % 60

    if (days > 0) return `${days}d ${hours}h`
    if (hours > 0) return `${hours}h ${minutes}m`
    if (minutes > 0) return `${minutes}m ${seconds.toString().padStart(2, "0")}s`
    return `${seconds}s`
  }

  money(value) {
    const amount = Number.parseFloat(value || "0")
    if (!Number.isFinite(amount)) return "$0"
    return `$${Math.round(amount).toLocaleString()}`
  }
}
