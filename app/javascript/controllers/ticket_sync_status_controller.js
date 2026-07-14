import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["button", "panel", "state", "detail", "lastSuccess", "counts", "duration", "weatherButton", "weatherPanel", "weatherState", "weatherDetail", "weatherLastSuccess", "weatherCounts", "weatherDuration", "weatherMeter", "weatherLoader"]
  static values = {
    interval: { type: Number, default: 5000 },
    url: String
  }

  connect() {
    this.refresh = this.refresh.bind(this)
    this.wasActive = this.element.dataset.ticketSyncActive === "true"
    this.weatherWasActive = this.element.dataset.weatherSyncActive === "true"
    this.refreshQueued = false
    this.refresh()
    this.timer = window.setInterval(this.refresh, this.intervalValue)
  }

  disconnect() {
    if (this.timer) window.clearInterval(this.timer)
  }

  async refresh() {
    if (!this.hasUrlValue || document.hidden) return

    try {
      const response = await fetch(this.urlValue, {
        headers: { Accept: "application/json", "X-Requested-With": "XMLHttpRequest" },
        credentials: "same-origin"
      })
      if (!response.ok) return

      this.render(await response.json())
    } catch (_error) {
      // Sync status is advisory UI; keep the last rendered state on transient fetch errors.
    }
  }

  render(data) {
    const active = Boolean(data.active)
    const contactActive = Boolean(data.contact_sync_active)
    const weather = data.weather_scan || {}
    const weatherActive = Boolean(weather.active)
    const weatherLocked = weatherActive || Boolean(weather.fresh_today)

    if (this.hasStateTarget) this.stateTarget.textContent = String(data.state_label || "sync idle").toUpperCase()
    if (this.hasDetailTarget) this.detailTarget.textContent = data.detail_label || ""
    if (this.hasLastSuccessTarget) this.lastSuccessTarget.textContent = data.last_success_label || "No successful ticket sync yet."
    if (this.hasCountsTarget) this.countsTarget.textContent = data.counts_label || ""
    if (this.hasDurationTarget) this.durationTarget.textContent = data.duration_label ? `duration ${data.duration_label}` : ""
    const button = this.syncButton()
    if (button) button.disabled = contactActive || button.dataset.hubspotConfigured !== "true"
    if (this.hasWeatherButtonTarget) this.weatherButtonTarget.disabled = weatherLocked

    if (this.hasPanelTarget) {
      this.panelTarget.classList.toggle("border-pink-300", active)
      this.panelTarget.classList.toggle("bg-pink-950/25", active)
      this.panelTarget.classList.toggle("text-pink-100", active)
      this.panelTarget.classList.toggle("border-green-300/60", !active && data.state === "success")
      this.panelTarget.classList.toggle("bg-green-950/20", !active && data.state === "success")
      this.panelTarget.classList.toggle("text-green-100", !active && data.state === "success")
      this.panelTarget.classList.toggle("border-teal-300/70", !active && data.state === "failed")
      this.panelTarget.classList.toggle("bg-teal-950/25", !active && data.state === "failed")
      this.panelTarget.classList.toggle("text-teal-100", !active && data.state === "failed")
    }

    if (this.wasActive && !contactActive && data.state === "success" && !this.refreshQueued) {
      this.refreshQueued = true
      this.refreshFrames(700)
    }

    this.renderWeather(weather, weatherActive)

    if (this.weatherWasActive && !weatherActive && weather.state === "success" && !this.refreshQueued) {
      this.refreshQueued = true
      this.refreshFrames(700)
    }

    this.wasActive = contactActive
    this.weatherWasActive = weatherActive
  }

  renderWeather(weather, active) {
    if (this.hasWeatherStateTarget) this.weatherStateTarget.textContent = String(weather.state_label || "storm watch idle").toUpperCase()
    if (this.hasWeatherDetailTarget) this.weatherDetailTarget.textContent = weather.detail_label || ""
    if (this.hasWeatherLastSuccessTarget) this.weatherLastSuccessTarget.textContent = weather.last_success_label || "No successful Storm Watch scan yet."
    if (this.hasWeatherCountsTarget) this.weatherCountsTarget.textContent = weather.counts_label || ""
    if (this.hasWeatherDurationTarget) this.weatherDurationTarget.textContent = weather.duration_label ? `duration ${weather.duration_label}` : ""
    if (this.hasWeatherMeterTarget) this.weatherMeterTarget.style.width = `${active ? Number(weather.progress_percent || 0) : 0}%`
    if (this.hasWeatherLoaderTarget) this.weatherLoaderTarget.hidden = !active

    if (!this.hasWeatherPanelTarget) return

    this.weatherPanelTarget.classList.toggle("is-loading", active)
    this.weatherPanelTarget.classList.toggle("is-running", active)
    this.weatherPanelTarget.classList.toggle("is-ready", !active)
    this.weatherPanelTarget.classList.toggle("border-yellow-300", active)
    this.weatherPanelTarget.classList.toggle("bg-yellow-950/25", active)
    this.weatherPanelTarget.classList.toggle("text-yellow-100", active)
    this.weatherPanelTarget.classList.toggle("border-green-300/60", !active && weather.state === "success")
    this.weatherPanelTarget.classList.toggle("bg-green-950/20", !active && weather.state === "success")
    this.weatherPanelTarget.classList.toggle("text-green-100", !active && weather.state === "success")
    this.weatherPanelTarget.classList.toggle("border-teal-300/70", !active && weather.state === "failed")
    this.weatherPanelTarget.classList.toggle("bg-teal-950/25", !active && weather.state === "failed")
    this.weatherPanelTarget.classList.toggle("text-teal-100", !active && weather.state === "failed")
  }

  refreshFrames(delay = 0) {
    window.setTimeout(() => {
      const url = `${window.location.pathname}${window.location.search}`
      ;["deal_queue_stats", "deal_queue_processing_bay", "deal_queue_results"].forEach((id) => {
        const frame = document.getElementById(id)
        if (!frame || frame.tagName !== "TURBO-FRAME") return
        frame.src = url
      })
    }, delay)
  }

  syncButton() {
    if (!this.hasButtonTarget) return null
    if (this.buttonTarget.matches("button,input[type='submit']")) return this.buttonTarget

    const button = this.buttonTarget.querySelector("button,input[type='submit']")
    if (button && !button.dataset.hubspotConfigured) button.dataset.hubspotConfigured = this.buttonTarget.dataset.hubspotConfigured
    return button
  }
}
