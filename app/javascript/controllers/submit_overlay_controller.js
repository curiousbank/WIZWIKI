import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["button", "overlay", "seconds"]
  static values = {
    label: { type: String, default: "Working" }
  }

  connect() {
    this.elapsed = 0
  }

  start(event) {
    if (event?.target && !event.target.checkValidity?.()) return

    this.elapsed = 0
    this.element.classList.add("submit-overlay-active")
    if (this.hasOverlayTarget) this.overlayTarget.hidden = false
    if (this.hasButtonTarget) {
      this.buttonTarget.disabled = true
      this.buttonTarget.dataset.originalText ||= this.buttonTarget.textContent
      this.buttonTarget.textContent = this.labelValue.toUpperCase()
    }
    this.tick()
    this.timer = window.setInterval(() => this.tick(), 1000)
  }

  finish(event) {
    if (event?.detail?.success === false) this.stop()
  }

  disconnect() {
    this.stopTimer()
  }

  tick() {
    if (this.hasSecondsTarget) this.secondsTarget.textContent = `${this.elapsed}s`
    this.elapsed += 1
  }

  stop() {
    this.element.classList.remove("submit-overlay-active")
    if (this.hasOverlayTarget) this.overlayTarget.hidden = true
    if (this.hasButtonTarget) {
      this.buttonTarget.disabled = false
      if (this.buttonTarget.dataset.originalText) this.buttonTarget.textContent = this.buttonTarget.dataset.originalText
    }
    this.stopTimer()
  }

  stopTimer() {
    if (this.timer) window.clearInterval(this.timer)
    this.timer = null
  }
}
