import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static values = {
    delay: { type: Number, default: 180 }
  }

  connect() {
    this.timeout = null
  }

  disconnect() {
    clearTimeout(this.timeout)
  }

  queue() {
    clearTimeout(this.timeout)
    this.timeout = setTimeout(() => this.submit(), this.delayValue)
  }

submit() {
  if (this.element.requestSubmit) this.element.requestSubmit()
  else this.element.submit()
}

refreshFrames() {
  const params = new URLSearchParams(new FormData(this.element))
  const url = `${this.element.action}?${params.toString()}`
  const frameIds = ["deal_queue_stats"]

  frameIds.forEach((id) => {
    const frame = document.getElementById(id)
    if (!frame || frame.tagName !== "TURBO-FRAME") return

    frame.src = url
    frame.reload?.()
  })
}
}
