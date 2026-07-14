import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["senderName", "senderPhone", "smsBody", "emailSubject", "emailBody"]

  connect() {
    this.captureSelectedTemplates()
    this.renderTemplates()
  }

  selectSms(event) {
    const body = event.currentTarget.dataset.commsLabBody
    if (body !== undefined && this.hasSmsBodyTarget) this.renderTemplate(this.smsBodyTarget, body)
  }

  selectEmail(event) {
    const subject = event.currentTarget.dataset.commsLabSubject
    const body = event.currentTarget.dataset.commsLabBody

    if (subject !== undefined && this.hasEmailSubjectTarget) this.renderTemplate(this.emailSubjectTarget, subject)
    if (body !== undefined && this.hasEmailBodyTarget) this.renderTemplate(this.emailBodyTarget, body)
  }

  senderChanged() {
    this.renderTemplates()
  }

  close() {
    const details = this.element.closest("details")
    if (details) details.open = false
  }

  captureSelectedTemplates() {
    const selectedSms = this.element.querySelector("input[name='selected_sms_id']:checked")
    const selectedEmail = this.element.querySelector("input[name='selected_email_id']:checked")

    if (selectedSms && this.hasSmsBodyTarget && !this.smsBodyTarget.dataset.commsLabTemplate) {
      this.smsBodyTarget.dataset.commsLabTemplate = selectedSms.dataset.commsLabBody || this.smsBodyTarget.value
    }

    if (selectedEmail) {
      if (this.hasEmailSubjectTarget && !this.emailSubjectTarget.dataset.commsLabTemplate) {
        this.emailSubjectTarget.dataset.commsLabTemplate = selectedEmail.dataset.commsLabSubject || this.emailSubjectTarget.value
      }
      if (this.hasEmailBodyTarget && !this.emailBodyTarget.dataset.commsLabTemplate) {
        this.emailBodyTarget.dataset.commsLabTemplate = selectedEmail.dataset.commsLabBody || this.emailBodyTarget.value
      }
    }
  }

  renderTemplates() {
    const targets = []
    if (this.hasSmsBodyTarget) targets.push(this.smsBodyTarget)
    if (this.hasEmailSubjectTarget) targets.push(this.emailSubjectTarget)
    if (this.hasEmailBodyTarget) targets.push(this.emailBodyTarget)

    targets.forEach((target) => this.renderTemplate(target, target.dataset.commsLabTemplate || target.value))
  }

  renderTemplate(target, template) {
    target.dataset.commsLabTemplate = template
    target.value = this.replaceSenderName(template)
  }

  replaceSenderName(value) {
    const sender = this.senderNameValue()
    const phone = this.senderPhoneValue()
    return String(value || "")
      .replace(/\[(?:your name|sender name|name)\]/gi, sender)
      .replace(/\[(?:your phone|sender phone|phone number|callback number)\]/gi, phone || "reply here")
  }

  senderNameValue() {
    if (!this.hasSenderNameTarget) return "WIZWIKI Marketing"

    const value = this.senderNameTarget.value.trim()
    return value || "WIZWIKI Marketing"
  }

  senderPhoneValue() {
    if (!this.hasSenderPhoneTarget) return ""

    return this.senderPhoneTarget.value.trim()
  }
}
