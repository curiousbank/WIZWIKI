import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static values = { endpoint: String }
  static targets = ["status"]

  capture(event) {
    event.preventDefault()

    if (!navigator.geolocation) {
      this.statusTarget.textContent = "This browser cannot share location."
      return
    }

    this.statusTarget.textContent = "Waiting for browser permission..."
    navigator.geolocation.getCurrentPosition(
      ({ coords }) => this.submit(coords),
      (error) => {
        this.statusTarget.textContent = `Location not shared: ${error.message}`
      },
      { enableHighAccuracy: false, timeout: 12000, maximumAge: 300000 }
    )
  }

  async submit(coords) {
    this.statusTarget.textContent = "Saving approved location..."
    try {
      const response = await fetch(this.endpointValue, {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          "X-CSRF-Token": this.csrfToken()
        },
        body: JSON.stringify({
          latitude: coords.latitude,
          longitude: coords.longitude,
          accuracy: coords.accuracy
        })
      })
      const data = await response.json()
      if (data.ok) {
        this.statusTarget.textContent = data.zip ? `Saved. ZIP ${data.zip} is now attached to this conversation.` : "Saved. Location is now attached to this conversation."
      } else {
        this.statusTarget.textContent = data.error || "Location could not be saved."
      }
    } catch (error) {
      this.statusTarget.textContent = `Location could not be saved: ${error.message}`
    }
  }

  csrfToken() {
    const tag = document.querySelector("meta[name='csrf-token']")
    return tag ? tag.content : ""
  }
}
