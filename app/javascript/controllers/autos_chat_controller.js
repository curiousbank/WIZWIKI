import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["pending", "submit", "timer"]

  connect() {
    this.pendingStartedAt = null
    this.pendingTimer = null
  }

  disconnect() {
    this.stopPendingTimer()
  }

  start() {
    if (this.hasPendingTarget) this.pendingTarget.classList.remove("hidden")
    this.startPendingTimer()
    if (this.hasSubmitTarget) {
      this.submitTarget.disabled = true
      this.submitTarget.classList.add("opacity-60", "cursor-wait")
    }
  }

  stop() {
    if (this.hasPendingTarget) this.pendingTarget.classList.add("hidden")
    this.stopPendingTimer()
    if (this.hasSubmitTarget) {
      this.submitTarget.disabled = false
      this.submitTarget.classList.remove("opacity-60", "cursor-wait")
    }
    window.dispatchEvent(new CustomEvent("autos:brain-power-refresh"))
    window.dispatchEvent(new CustomEvent("autos:ask-refresh"))
  }

  startPendingTimer() {
    this.pendingStartedAt = Date.now()
    this.updatePendingTimer()
    if (this.pendingTimer) window.clearInterval(this.pendingTimer)
    this.pendingTimer = window.setInterval(() => this.updatePendingTimer(), 1000)
  }

  stopPendingTimer() {
    if (this.pendingTimer) window.clearInterval(this.pendingTimer)
    this.pendingTimer = null
    this.pendingStartedAt = null
    this.setTimerText("00:00")
  }

  updatePendingTimer() {
    if (!this.pendingStartedAt) return
    const elapsedSeconds = Math.max(0, Math.floor((Date.now() - this.pendingStartedAt) / 1000))
    this.setTimerText(this.formatDuration(elapsedSeconds))
  }

  setTimerText(text) {
    this.timerTargets.forEach((timer) => { timer.textContent = text })
  }

  formatDuration(seconds) {
    const minutes = Math.floor(seconds / 60).toString().padStart(2, "0")
    const remainder = Math.floor(seconds % 60).toString().padStart(2, "0")
    return `${minutes}:${remainder}`
  }
}
