import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = [
    "overlay",
    "badge",
    "pending",
    "activity",
    "updated",
    "notice",
    "scanButton",
    "pendingStat",
    "approvedStat",
    "embeddedStat",
    "qualityStat",
  ]

  static values = {
    feedUrl: String,
    scanUrl: String,
    approveUrlTemplate: String,
    rejectUrlTemplate: String,
    revokeUrlTemplate: String,
    pollMs: { type: Number, default: 5000 },
    autoOpen: { type: Boolean, default: true },
  }

  connect() {
    this.refreshing = false
    if (this.autoOpenValue) this.open()
    this.refresh()
    this.timer = window.setInterval(() => this.refresh(), this.pollMsValue)
  }

  disconnect() {
    if (this.timer) window.clearInterval(this.timer)
    this.releasePage()
  }

  open() {
    this.overlayTarget.classList.remove("hidden")
    this.overlayTarget.setAttribute("aria-hidden", "false")
    document.body.style.overflow = "hidden"
  }

  close() {
    this.overlayTarget.classList.add("hidden")
    this.overlayTarget.setAttribute("aria-hidden", "true")
    this.releasePage()
  }

  async refresh() {
    if (this.refreshing) return

    this.refreshing = true
    try {
      const response = await fetch(this.feedUrlValue, {
        credentials: "same-origin",
        headers: { Accept: "application/json" },
      })
      const payload = await response.json()
      if (!response.ok) throw new Error(payload.error || "Learning feed could not be loaded.")

      this.render(payload)
    } catch (error) {
      this.showNotice(error.message, true)
    } finally {
      this.refreshing = false
    }
  }

  async scan() {
    this.scanButtonTarget.disabled = true
    this.scanButtonTarget.textContent = "SCANNING"
    try {
      const payload = await this.request(this.scanUrlValue)
      this.showNotice(payload.message || "Learning scan queued.")
      window.setTimeout(() => this.refresh(), 1200)
    } catch (error) {
      this.showNotice(error.message, true)
    } finally {
      this.scanButtonTarget.disabled = false
      this.scanButtonTarget.textContent = "RUN SCAN"
    }
  }

  render(payload) {
    const stats = payload.stats || {}
    this.pendingStatTarget.textContent = this.number(stats.pending)
    this.approvedStatTarget.textContent = this.number(stats.approved)
    this.embeddedStatTarget.textContent = this.number(stats.embedded)
    this.qualityStatTarget.textContent = this.number(stats.quality_flags)
    this.badgeTarget.textContent = this.number(stats.pending)
    this.updatedTarget.textContent = `LIVE // ${this.time(payload.generated_at)}`
    this.renderCandidates(payload.candidates || [])
    this.renderActivity(payload.activity || [])
  }

  renderCandidates(candidates) {
    this.pendingTarget.replaceChildren()
    if (candidates.length === 0) {
      this.pendingTarget.append(this.emptyState("No promotions are waiting for review."))
      return
    }

    candidates.forEach((candidate) => this.pendingTarget.append(this.candidateCard(candidate)))
  }

  candidateCard(candidate) {
    const card = this.node("article", "border border-white/20 bg-[#111] p-4")
    const header = this.node("div", "flex items-start justify-between gap-4")
    const titleBlock = this.node("div", "min-w-0")
    titleBlock.append(
      this.textNode("p", "PENDING HUMAN REVIEW", "font-mono text-[10px] font-black uppercase text-lime-300"),
      this.textNode("h3", candidate.source_label || candidate.title, "mt-1 truncate text-sm font-black text-white"),
      this.textNode("p", `${candidate.product} // ${candidate.outcome} // ${candidate.inbound_count} IN / ${candidate.outbound_count} OUT`, "mt-1 font-mono text-[10px] uppercase text-zinc-400")
    )
    const score = this.textNode("span", `${candidate.score || 0}%`, "border border-lime-300/50 bg-lime-300 px-2 py-1 font-mono text-xs font-black text-black")
    header.append(titleBlock, score)
    card.append(header)

    const evidence = this.node("div", "mt-3 flex flex-wrap gap-1.5")
    ;(candidate.evidence || []).forEach((item) => {
      evidence.append(this.textNode("span", item, "border border-white/15 px-2 py-1 font-mono text-[9px] uppercase text-zinc-300"))
    })
    card.append(evidence)

    const details = this.node("details", "mt-3 border-t border-white/10 pt-3")
    details.append(this.textNode("summary", "VIEW REDACTED EVIDENCE", "cursor-pointer font-mono text-[10px] font-black uppercase text-cyan-200"))
    const body = this.textNode("pre", candidate.body || "No evidence body available.", "mt-3 max-h-64 overflow-auto whitespace-pre-wrap border border-white/10 bg-black p-3 font-mono text-[10px] leading-5 text-zinc-300")
    details.append(body)
    card.append(details)

    const note = this.node("textarea", "mt-3 min-h-16 w-full resize-y border border-white/20 bg-black px-3 py-2 text-xs text-white outline-none focus:border-cyan-300")
    note.maxLength = 500
    note.placeholder = "Reviewer note (optional)"
    note.setAttribute("aria-label", `Reviewer note for ${candidate.source_label || candidate.title}`)
    card.append(note)

    const actions = this.node("div", "mt-3 grid grid-cols-2 gap-2")
    const approve = this.actionButton("APPROVE + EMBED", "bg-lime-300 text-black hover:bg-white")
    const reject = this.actionButton("REJECT", "bg-zinc-800 text-white hover:bg-white hover:text-black")
    approve.addEventListener("click", () => this.review(candidate.id, "approve", note, [approve, reject]))
    reject.addEventListener("click", () => this.review(candidate.id, "reject", note, [approve, reject]))
    actions.append(approve, reject)
    card.append(actions)
    return card
  }

  renderActivity(items) {
    this.activityTarget.replaceChildren()
    if (items.length === 0) {
      this.activityTarget.append(this.emptyState("No adaptive learning activity yet."))
      return
    }

    items.forEach((item) => {
      const row = this.node("article", "border-b border-white/10 py-3 last:border-0")
      const header = this.node("div", "flex items-start justify-between gap-3")
      const copy = this.node("div", "min-w-0")
      copy.append(
        this.textNode("p", `${item.state} // ${item.retrieval_role || item.kind}`, "font-mono text-[9px] font-black uppercase text-cyan-200"),
        this.textNode("p", item.title, "mt-1 truncate text-xs font-bold text-zinc-200"),
        this.textNode("p", this.time(item.updated_at), "mt-1 font-mono text-[9px] text-zinc-500")
      )
      header.append(copy)

      if (item.can_revoke) {
        const revoke = this.actionButton("REMOVE", "border border-teal-300/50 bg-transparent text-teal-200 hover:bg-teal-300 hover:text-black")
        revoke.addEventListener("click", () => this.review(item.id, "revoke", null, [revoke]))
        header.append(revoke)
      }
      row.append(header)
      this.activityTarget.append(row)
    })
  }

  async review(id, mode, note, buttons) {
    buttons.forEach((button) => { button.disabled = true })
    try {
      const template = mode === "approve" ? this.approveUrlTemplateValue : mode === "reject" ? this.rejectUrlTemplateValue : this.revokeUrlTemplateValue
      const payload = await this.request(template.replace("__ID__", String(id)), {
        review_note: note?.value || "",
      })
      this.showNotice(payload.message || "Learning record updated.")
      await this.refresh()
    } catch (error) {
      this.showNotice(error.message, true)
      buttons.forEach((button) => { button.disabled = false })
    }
  }

  async request(url, body = {}) {
    const response = await fetch(url, {
      method: "POST",
      credentials: "same-origin",
      headers: {
        Accept: "application/json",
        "Content-Type": "application/json",
        "X-CSRF-Token": document.querySelector("meta[name='csrf-token']")?.content || "",
      },
      body: JSON.stringify(body),
    })
    const payload = await response.json()
    if (!response.ok) throw new Error(payload.error || "The learning action failed.")
    return payload
  }

  showNotice(message, error = false) {
    this.noticeTarget.textContent = message
    this.noticeTarget.classList.toggle("text-teal-200", error)
    this.noticeTarget.classList.toggle("text-lime-200", !error)
    this.noticeTarget.classList.remove("hidden")
  }

  actionButton(label, colors) {
    const button = this.textNode("button", label, `cursor-pointer px-3 py-2 font-mono text-[10px] font-black uppercase disabled:cursor-wait disabled:opacity-40 ${colors}`)
    button.type = "button"
    return button
  }

  emptyState(message) {
    return this.textNode("p", message, "border border-dashed border-white/20 p-4 font-mono text-xs text-zinc-400")
  }

  textNode(tag, text, className) {
    const node = this.node(tag, className)
    node.textContent = text || ""
    return node
  }

  node(tag, className) {
    const node = document.createElement(tag)
    node.className = className
    return node
  }

  number(value) {
    return Number(value || 0).toLocaleString()
  }

  time(value) {
    if (!value) return "time unavailable"
    return new Intl.DateTimeFormat(undefined, { month: "short", day: "numeric", hour: "numeric", minute: "2-digit" }).format(new Date(value))
  }

  releasePage() {
    document.body.style.overflow = ""
  }
}
