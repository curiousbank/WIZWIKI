import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["audience", "panel", "buttonLabel", "workingLabel", "cloudDock", "commKitToggle", "commKitDirection", "localPrepToggle", "localPrepControl"]
  static values = {
    clientCount: { type: Number, default: 0 },
    amCount: { type: Number, default: 0 },
    copyMakerCount: { type: Number, default: 0 }
  }

  connect() {
    this.update()
  }

  close(event) {
    event?.preventDefault()
    this.element.closest("details")?.removeAttribute("open")
  }

  update() {
    const audience = this.selectedAudience()
    const label = this.labelFor(audience)

    this.panelTargets.forEach((panel) => {
      const active = panel.dataset.rptBuilderAudience === audience
      panel.hidden = !active
      panel.querySelectorAll("input, select, textarea").forEach((field) => {
        field.disabled = !active
      })
    })

    this.element.dataset.reportTimerAudienceValue = audience
    this.element.dataset.reportTimerReportCountValue = String(this.countFor(audience))
    if (this.hasCloudDockTarget) {
      const copyMode = audience === "copy_maker"
      this.cloudDockTarget.hidden = !copyMode
      this.cloudDockTarget.classList.toggle("is-disabled", !copyMode)
      this.cloudDockTarget.setAttribute("aria-disabled", copyMode ? "false" : "true")
      this.cloudDockTarget.querySelectorAll("input, select, textarea").forEach((field) => {
        field.disabled = !copyMode
      })
    }
    this.updateCommKitDirection(audience === "copy_maker")
    this.updateLocalPrepControl(audience === "copy_maker")
    if (this.hasButtonLabelTarget) this.buttonLabelTarget.textContent = label
    if (this.hasWorkingLabelTarget) this.workingLabelTarget.textContent = label
  }

  beforeSubmit() {
    this.update()
  }

  selectedAudience() {
    const value = this.hasAudienceTarget ? this.audienceTarget.value : "client"
    return ["client", "am", "copy_maker"].includes(value) ? value : "client"
  }

  labelFor(audience) {
    if (audience === "am") return "🧭 ACCOUNT REPORT"
    if (audience === "copy_maker") return "✒️ COPYWRITER"
    return "🤝 CLIENT REPORT"
  }

  updateCommKitDirection(copyMode) {
    if (!this.hasCommKitDirectionTarget) return

    const enabled = copyMode && (!this.hasCommKitToggleTarget || this.commKitToggleTarget.checked)
    this.commKitDirectionTarget.classList.toggle("is-disabled", !enabled)
    this.commKitDirectionTarget.setAttribute("aria-disabled", enabled ? "false" : "true")
    this.commKitDirectionTarget.querySelectorAll("input, select, textarea").forEach((field) => {
      field.disabled = !enabled
    })
  }

  updateLocalPrepControl(copyMode) {
    if (!this.hasLocalPrepControlTarget) return

    const enabled = copyMode && (!this.hasLocalPrepToggleTarget || this.localPrepToggleTarget.checked)
    this.localPrepControlTarget.hidden = false
    this.localPrepControlTarget.classList.toggle("is-disabled", !enabled)
    this.localPrepControlTarget.setAttribute("aria-disabled", enabled ? "false" : "true")
    this.localPrepControlTarget.querySelectorAll("input, select, textarea").forEach((field) => {
      field.disabled = !enabled
    })
  }

  countFor(audience) {
    if (audience === "am") return this.amCountValue
    if (audience === "copy_maker") return this.copyMakerCountValue
    return this.clientCountValue
  }
}
