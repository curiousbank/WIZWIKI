import { Controller } from "@hotwired/stimulus"
import { Turbo } from "@hotwired/turbo-rails"

export default class extends Controller {
  connect() {
    this.refresh = this.refresh.bind(this)
    this.updateThinkingTimer = this.updateThinkingTimer.bind(this)
    this.refreshing = false
    this.refreshUntil = this.pending() ? Date.now() + 600000 : Date.now() + 8000
    this.refreshTimeouts = []
    this.refreshTimer = window.setInterval(this.refresh, this.pending() ? 10000 : 6000)
    this.thinkingTimer = window.setInterval(this.updateThinkingTimer, 1000)
    this.sortThreads()
    this.pinThreadsToTop()
    this.updateThinkingTimer()
    this.refreshTimeouts = [1500, 8000, 20000, 45000, 90000, 180000, 300000].map((delay) =>
      window.setTimeout(this.refresh, delay)
    )
  }

  disconnect() {
    this.stopRefreshTimer()
    if (this.thinkingTimer) window.clearInterval(this.thinkingTimer)
    this.refreshTimeouts.forEach((timeout) => window.clearTimeout(timeout))
    this.refreshTimeouts = []
  }

  async refresh() {
    if (!this.shouldRefresh() || !this.refreshUrl()) {
      if (!this.shouldRefresh()) this.stopRefreshTimer()
      return
    }
    if (this.refreshing) return
    this.refreshing = true

    const url = new URL(this.refreshUrl(), window.location.origin)
    const version = this.element.dataset.askAutopilotVersion
    if (version) url.searchParams.set("version", version)

    try {
      const response = await fetch(url.toString(), {
        headers: {
          "Accept": "text/vnd.turbo-stream.html",
          "X-Requested-With": "XMLHttpRequest"
        },
        credentials: "same-origin"
      })
      if (response.status === 204 || !response.ok) return

      const html = await response.text()
      if (!html) return

      Turbo.renderStreamMessage(html)
      window.setTimeout(() => {
        this.sortThreads()
        this.pinThreadsToTop()
      }, 0)
      if (!this.shouldRefresh()) this.stopRefreshTimer()
    } catch (_error) {
      // The next interval can retry; simulator polling should never block the page.
    } finally {
      this.refreshing = false
    }
  }

  updateThinkingTimer() {
    this.visibleThinkingNodes().forEach((node) => {
      const startedAt = Date.parse(
        node.dataset.askAutopilotThinkingStartedAt ||
          this.element.dataset.askAutopilotPendingStartedAt ||
          ""
      )
      if (Number.isNaN(startedAt)) return

      const elapsedSeconds = Math.max(0, Math.floor((Date.now() - startedAt) / 1000))
      const timer = node.querySelector("[data-ask-autopilot-thinking-timer]")
      const bar = node.querySelector("[data-ask-autopilot-thinking-bar]")
      if (timer) timer.textContent = this.formatDuration(elapsedSeconds)
      if (bar) bar.style.width = `${Math.min(96, 14 + elapsedSeconds * 2.4)}%`
    })
    this.updateElapsedTimers()
  }

  visibleThinkingNodes() {
    return Array.from(this.element.querySelectorAll("[data-ask-autopilot-thinking]")).filter((node) => {
      if (!node || node.classList?.contains("hidden")) return false
      const style = window.getComputedStyle(node)
      return style.display !== "none" && style.visibility !== "hidden" && style.opacity !== "0"
    })
  }

  updateElapsedTimers() {
    this.element.querySelectorAll("[data-ask-autopilot-elapsed-timer]").forEach((timer) => {
      const startedAt = Date.parse(timer.dataset.askAutopilotElapsedStartedAt || "")
      if (Number.isNaN(startedAt)) return

      const elapsedSeconds = Math.max(0, Math.floor((Date.now() - startedAt) / 1000))
      timer.textContent = this.formatDuration(elapsedSeconds)
    })
  }

  scrollThread() {
    this.element.querySelectorAll("[data-ask-autopilot-thread]").forEach((thread) => {
      this.pinThreadToTop(thread)
    })
  }

  pinThreadsToTop() {
    const pin = () => this.scrollThread()
    pin()
    window.requestAnimationFrame(pin)
    window.setTimeout(pin, 100)
  }

  pinThreadToTop(thread) {
    if (!thread) return

    const previousBehavior = thread.style.scrollBehavior
    thread.style.scrollBehavior = "auto"
    thread.scrollTop = 0
    if (thread.scrollTo) thread.scrollTo({ top: 0, left: 0, behavior: "auto" })
    thread.dataset.wizwikiPinnedTopAt = Date.now().toString()

    window.requestAnimationFrame(() => {
      thread.scrollTop = 0
      if (previousBehavior) thread.style.scrollBehavior = previousBehavior
      else thread.style.removeProperty("scroll-behavior")
    })
  }

  sortThreads() {
    this.element.querySelectorAll("[data-ask-autopilot-thread]").forEach((thread) => {
      const rows = Array.from(thread.querySelectorAll("[data-wizwiki-copy-time]"))
      if (rows.length < 2) return

      rows
        .map((row, index) => ({
          index,
          row,
          time: Date.parse(row.dataset.wizwikiCopyTime || "")
        }))
        .sort((left, right) => {
          const leftTimed = Number.isFinite(left.time)
          const rightTimed = Number.isFinite(right.time)
          if (leftTimed && rightTimed && left.time !== right.time) return right.time - left.time
          if (leftTimed !== rightTimed) return leftTimed ? -1 : 1
          return left.index - right.index
        })
        .forEach(({ row }) => thread.appendChild(row))
    })
  }

  active() {
    return this.element.classList.contains("is-active")
  }

  pending() {
    return this.element.dataset.askAutopilotPending === "true"
  }

  shouldRefresh() {
    return this.active() && (this.pending() || Date.now() < this.refreshUntil)
  }

  refreshUrl() {
    return this.element.dataset.askAutopilotRefreshUrl
  }

  stopRefreshTimer() {
    if (this.refreshTimer) window.clearInterval(this.refreshTimer)
    this.refreshTimer = null
  }

  formatDuration(seconds) {
    const minutes = Math.floor(seconds / 60).toString().padStart(2, "0")
    const remainder = Math.floor(seconds % 60).toString().padStart(2, "0")
    return `${minutes}:${remainder}`
  }
}
