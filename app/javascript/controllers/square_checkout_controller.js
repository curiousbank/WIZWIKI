import { Controller } from "@hotwired/stimulus"

let squareScriptPromise

export default class extends Controller {
  static targets = ["button", "card", "status", "token"]
  static values = {
    applicationId: String,
    configured: Boolean,
    environment: String,
    locationId: String
  }

  connect() {
    this.tokenized = false

    if (!this.configuredValue) {
      this.setStatus("Square checkout is waiting for application and location credentials.")
      return
    }

    this.mountCard()
  }

  async submit(event) {
    if (this.tokenized || !this.configuredValue) return

    event.preventDefault()
    if (!this.card) {
      this.setStatus("Square card terminal is still loading. Try again in a moment.")
      return
    }

    this.toggleButton(true)
    this.setStatus("Tokenizing card with Square...")

    try {
      const result = await this.card.tokenize()
      if (result.status !== "OK") {
        this.setStatus(this.errorMessage(result.errors))
        this.toggleButton(false)
        return
      }

      this.tokenTarget.value = result.token
      this.tokenized = true
      this.element.requestSubmit()
    } catch (error) {
      this.setStatus(error.message || "Square card checkout could not start.")
      this.toggleButton(false)
    }
  }

  async mountCard() {
    try {
      await this.loadSquareScript()
      const payments = window.Square.payments(this.applicationIdValue, this.locationIdValue)
      this.card = await payments.card()
      await this.card.attach("#square-card-container")
      this.setStatus("Square secure card terminal ready.")
    } catch (error) {
      this.setStatus(error.message || "Square card terminal could not load.")
    }
  }

  loadSquareScript() {
    if (window.Square) return Promise.resolve()
    if (squareScriptPromise) return squareScriptPromise

    squareScriptPromise = new Promise((resolve, reject) => {
      const script = document.createElement("script")
      script.src = this.environmentValue === "sandbox" ? "https://sandbox.web.squarecdn.com/v1/square.js" : "https://web.squarecdn.com/v1/square.js"
      script.onload = resolve
      script.onerror = () => reject(new Error("Square checkout script could not load."))
      document.head.appendChild(script)
    })

    return squareScriptPromise
  }

  errorMessage(errors) {
    const first = Array.isArray(errors) ? errors[0] : null
    return first?.message || "Square could not tokenize that card. Check the card details and try again."
  }

  setStatus(message) {
    if (this.hasStatusTarget) this.statusTarget.textContent = message
  }

  toggleButton(disabled) {
    if (!this.hasButtonTarget) return

    this.buttonTarget.disabled = disabled
    this.buttonTarget.classList.toggle("opacity-60", disabled)
    this.buttonTarget.classList.toggle("cursor-wait", disabled)
  }
}
