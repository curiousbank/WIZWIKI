import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["toggle", "panel"]

  connect() {
    this.update()
  }

  update() {
    if (!this.hasPanelTarget) return

    const enabled = this.hasToggleTarget && this.toggleTarget.checked
    this.panelTarget.hidden = !enabled
  }
}
