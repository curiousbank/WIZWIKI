import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["loader"]

  start() {
    this.element.classList.add("is-loading")
    this.element.classList.remove("is-ready")

    if (this.hasLoaderTarget) {
      this.loaderTarget.hidden = false
    }

    const button = this.element.querySelector(".comms-command-sample_owner-wall-button")
    if (button) {
      button.setAttribute("aria-busy", "true")
    }
  }

  stop() {
    this.element.classList.remove("is-loading")

    if (this.hasLoaderTarget && !this.element.classList.contains("is-running")) {
      this.loaderTarget.hidden = true
    }

    const button = this.element.querySelector(".comms-command-sample_owner-wall-button")
    if (button) {
      button.removeAttribute("aria-busy")
    }
  }
}
