import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["bar", "remaining", "used", "status"]
  static values = {
    url: String,
    interval: { type: Number, default: 15000 }
  }

  connect() {
    this.refresh = this.refresh.bind(this)
    window.addEventListener("autos:brain-power-refresh", this.refresh)
    this.refresh()
    this.timer = window.setInterval(this.refresh, this.intervalValue)
  }

  disconnect() {
    window.removeEventListener("autos:brain-power-refresh", this.refresh)
    if (this.timer) window.clearInterval(this.timer)
  }

  async refresh() {
    if (!this.hasUrlValue || document.hidden) return

    try {
      const response = await fetch(this.urlValue, {
        headers: { "Accept": "application/json", "X-Requested-With": "XMLHttpRequest" },
        credentials: "same-origin"
      })
      if (!response.ok) return

      this.render(await response.json())
    } catch (_error) {
      // Keep the last known value. Brain power is status UI, not a blocking control.
    }
  }

  render(data) {
    const percent = Math.max(0, Math.min(100, Number(data.percent_left || 0)))
    if (this.hasBarTarget) this.barTarget.style.width = `${percent}%`
    if (this.hasRemainingTarget) this.remainingTarget.textContent = `${this.format(data.remaining)} WIZWIKI_CRED LEFT`
    if (this.hasUsedTarget) this.usedTarget.textContent = `used ${this.format(data.used)} / ${this.format(data.budget)}`
    if (this.hasStatusTarget) {
      this.statusTarget.textContent = data.status_label || (data.configured ? "openai" : "openai key needed")
      this.statusTarget.classList.toggle("text-pink-300", Boolean(data.configured))
      this.statusTarget.classList.toggle("text-teal-300", !data.configured)
    }
  }

  format(value) {
    return new Intl.NumberFormat().format(Number(value || 0))
  }
}
