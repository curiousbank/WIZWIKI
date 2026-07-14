import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["button", "seconds", "status"]

  connect() {
    this.elapsed = 0
  }

  start() {
    this.elapsed = 0
    this.element.classList.add("canva-build-active")
    if (this.hasButtonTarget) {
      this.buttonTarget.disabled = true
      this.buttonTarget.textContent = "BUILDING CANVA"
    }
    if (this.hasStatusTarget) this.statusTarget.hidden = false
    this.tick()
    this.timer = window.setInterval(() => this.tick(), 1000)
  }

  disconnect() {
    if (this.timer) window.clearInterval(this.timer)
  }

  tick() {
    if (this.hasSecondsTarget) this.secondsTarget.textContent = `${this.elapsed}s`
    this.elapsed += 1
  }
}
