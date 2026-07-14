import { Controller } from "@hotwired/stimulus"

const DOMAIN_STRENGTHS = {
  executing: ["Achiever", "Arranger", "Belief", "Consistency", "Deliberative", "Discipline", "Focus", "Responsibility", "Restorative"],
  influencing: ["Activator", "Command", "Communication", "Competition", "Maximizer", "Self-Assurance", "Significance", "Woo"],
  relationship: ["Adaptability", "Connectedness", "Developer", "Empathy", "Harmony", "Includer", "Individualization", "Positivity", "Relator"],
  strategic: ["Analytical", "Context", "Futuristic", "Ideation", "Input", "Intellection", "Learner", "Strategic"]
}

export default class extends Controller {
  static targets = [
    "profileRow",
    "statusButton",
    "statusCount",
    "domainButton",
    "domainCount",
    "traitPanel",
    "traitClear",
    "visibleCount",
    "teamSize",
    "teamHeading",
    "teamPanel",
    "emptyState",
    "searchInput"
  ]

  connect() {
    this.status = null
    this.selectedDomains = new Set()
    this.selectedTraits = new Set()
    this.teamSize = this.hasTeamSizeTarget ? Number(this.teamSizeTarget.value) || 5 : 5
    this.searchQuery = ""
    this.refresh()
  }

  toggleStatus(event) {
    const nextStatus = event.currentTarget.dataset.status
    this.status = nextStatus === "profiles" || this.status === nextStatus ? null : nextStatus
    this.selectedTraits.clear()
    this.refresh()
  }

  toggleDomain(event) {
    const nextDomain = event.currentTarget.dataset.domain
    if (event.currentTarget.disabled) return

    if (this.selectedDomains.has(nextDomain)) {
      this.selectedDomains.delete(nextDomain)
    } else {
      this.selectedDomains.add(nextDomain)
    }
    this.selectedTraits.clear()
    this.refresh()
  }

  changeTeamSize(event) {
    this.teamSize = Math.min(10, Math.max(2, Number(event.currentTarget.value) || 5))
    this.renderTeams()
  }

  updateSearch(event) {
    this.searchQuery = event.currentTarget.value.toString().trim().toLowerCase()
    this.renderProfiles()
    this.renderTeams()
  }

  clearFilters() {
    this.status = null
    this.selectedDomains.clear()
    this.selectedTraits.clear()
    this.searchQuery = ""
    if (this.hasSearchInputTarget) this.searchInputTarget.value = ""
    this.refresh()
  }

  clearTraits() {
    this.selectedTraits.clear()
    this.renderTraitButtons()
    this.renderProfiles()
    this.renderTeams()
  }

  refresh() {
    this.syncStatusButtons()
    this.syncDomainCountsAndButtons()
    this.pruneUnavailableTraits()
    this.renderTraitButtons()
    this.renderProfiles()
    this.renderTeams()
  }

  renderProfiles() {
    const visibleRows = this.filteredRows()
    const visibleSet = new Set(visibleRows)

    this.profileRowTargets.forEach((row) => {
      const visible = visibleSet.has(row)
      row.hidden = false
      row.classList.toggle("hidden", false)
      row.style.display = visible ? "" : "none"
      row.dataset.visible = visible ? "1" : "0"
    })

    if (this.hasVisibleCountTarget) {
      const filters = [
        this.status ? `status ${this.status.replace("_", " ")}` : null,
        this.selectedDomains.size > 0 ? `${this.selectedDomains.size} domain${this.selectedDomains.size === 1 ? "" : "s"}` : null,
        this.selectedTraits.size > 0 ? `${this.selectedTraits.size} top trait${this.selectedTraits.size === 1 ? "" : "s"}` : null,
        this.searchQuery ? `search "${this.searchQuery}"` : null
      ].filter(Boolean).join(" // ")
      this.visibleCountTarget.textContent = `${visibleRows.length} visible profiles${filters ? ` // ${filters}` : ""}`
    }

    if (this.hasEmptyStateTarget) {
      this.emptyStateTarget.hidden = visibleRows.length > 0
    }
  }

  renderTraitButtons() {
    if (!this.hasTraitPanelTarget) return

    const rows = this.rowsForStatusAndDomain()
    const traitCounts = this.traitCounts(rows)
    const traits = this.traitsForCurrentDomain(traitCounts)

    this.traitPanelTarget.innerHTML = ""

    if (this.hasTraitClearTarget) {
      this.traitClearTarget.hidden = this.selectedTraits.size === 0
    }

    if (traits.length === 0) {
      const empty = document.createElement("span")
      empty.className = "font-mono text-xs text-zinc-500"
      empty.textContent = "No shared top 4 traits in this filtered set."
      this.traitPanelTarget.append(empty)
      return
    }

    traits.forEach((trait) => {
      const count = traitCounts.get(trait) || 0
      const selected = this.selectedTraits.has(trait)
      const button = document.createElement("button")
      button.type = "button"
      button.dataset.trait = trait
      button.disabled = count === 0
      button.setAttribute("aria-pressed", selected ? "true" : "false")
      button.className = [
        "team-filter-chip",
        "border",
        "border-dotted",
        "px-3",
        "py-2",
        "font-mono",
        "text-[11px]",
        "transition",
        count === 0 ? "opacity-30" : "hover:bg-zinc-700"
      ].join(" ")
      button.innerHTML = `<span>${this.escapeHtml(trait)}</span><span class="ml-2 opacity-70">${count}</span>`
      button.addEventListener("click", () => {
        if (this.selectedTraits.has(trait)) {
          this.selectedTraits.delete(trait)
        } else {
          this.selectedTraits.add(trait)
        }
        this.renderTraitButtons()
        this.renderProfiles()
        this.renderTeams()
      })
      this.traitPanelTarget.append(button)
    })
  }

  renderTeams() {
    if (!this.hasTeamPanelTarget) return

    const visibleRows = this.filteredRows().filter((row) => this.effectiveTopTraits(row).length > 0)
    const teams = this.buildTeams(visibleRows, this.teamSize)
    this.teamPanelTarget.innerHTML = ""

    if (this.hasTeamHeadingTarget) {
      this.teamHeadingTarget.textContent = `Suggested teams of ${this.teamSize}`
    }

    if (visibleRows.length === 0) {
      this.teamPanelTarget.innerHTML = `<p class="border border-dotted border-white/30 bg-white/5 p-4 font-mono text-xs text-zinc-300">Use profiles with strengths to generate teams.</p>`
      return
    }

    teams.forEach((team, index) => {
      const card = document.createElement("div")
      card.className = "border border-dotted border-white/25 bg-zinc-950/80 p-3"
      const strengthSpread = new Set(team.flatMap((row) => this.effectiveTopTraits(row))).size
      card.innerHTML = `
        <div class="flex items-center justify-between gap-3">
          <strong class="font-mono text-sm text-zinc-100">TEAM ${index + 1}</strong>
          <span class="font-mono text-[10px] text-zinc-500">${team.length}/${this.teamSize} // ${strengthSpread} top 4 traits</span>
        </div>
        <div class="mt-2 grid gap-2">
          ${team.map((row) => {
            const exec = this.flag(row, "exec")
            return `
              <div class="border border-dotted border-white/15 bg-black/60 p-2 font-mono text-xs text-zinc-200">
                <span class="${exec ? "text-teal-400" : "text-white"}">${this.escapeHtml(row.dataset.name || "Unknown")}</span>
                ${exec ? `<span class="ml-1 text-teal-500">exec</span>` : ""}
                <span class="text-zinc-500"> // ${this.escapeHtml(this.effectiveTopTraits(row).join(", "))}</span>
              </div>
            `
          }).join("")}
        </div>
      `
      this.teamPanelTarget.append(card)
    })
  }

  buildTeams(rows, size) {
    const pool = [...rows]
    const teams = []

    while (pool.length > 0) {
      const leaderIndex = pool.findIndex((row) => this.flag(row, "exec"))
      const leader = pool.splice(leaderIndex >= 0 ? leaderIndex : 0, 1)[0]
      const members = [leader]
      const usedTraits = new Set(this.effectiveTopTraits(leader))
      const usedDomains = new Set(this.effectiveDomains(leader))

      while (members.length < size && pool.length > 0) {
        let bestIndex = 0
        let bestScore = [-1, -1, -1, -1]

        pool.forEach((row, index) => {
          const uniqueDomains = this.effectiveDomains(row).filter((domain) => !usedDomains.has(domain)).length
          const uniqueTraits = this.effectiveTopTraits(row).filter((trait) => !usedTraits.has(trait)).length
          const roleBonus = row.dataset.role !== leader.dataset.role ? 1 : 0
          const execPenalty = this.flag(row, "exec") ? -1 : 0
          const score = [uniqueDomains, uniqueTraits, roleBonus, execPenalty]
          if (this.compareScore(score, bestScore) > 0) {
            bestScore = score
            bestIndex = index
          }
        })

        const candidate = pool.splice(bestIndex, 1)[0]
        members.push(candidate)
        this.effectiveTopTraits(candidate).forEach((trait) => usedTraits.add(trait))
        this.effectiveDomains(candidate).forEach((domain) => usedDomains.add(domain))
      }

      teams.push(members)
    }

    return teams
  }

  syncStatusButtons() {
    const activeStatus = this.status || "profiles"

    this.statusButtonTargets.forEach((button) => {
      button.setAttribute("aria-pressed", button.dataset.status === activeStatus ? "true" : "false")
    })

    this.statusCountTargets.forEach((target) => {
      target.textContent = this.statusCount(target.dataset.statusCount)
    })
  }

  syncDomainCountsAndButtons() {
    const baseRows = this.rowsForStatus()
    const counts = new Map()

    baseRows.forEach((row) => {
      this.effectiveDomains(row).forEach((domain) => counts.set(domain, (counts.get(domain) || 0) + 1))
    })

    let prunedDomain = false
    this.selectedDomains.forEach((domain) => {
      if ((counts.get(domain) || 0) === 0) {
        this.selectedDomains.delete(domain)
        prunedDomain = true
      }
    })
    if (prunedDomain) this.selectedTraits.clear()

    this.domainCountTargets.forEach((target) => {
      target.textContent = counts.get(target.dataset.domainCount) || 0
    })

    this.domainButtonTargets.forEach((button) => {
      const count = counts.get(button.dataset.domain) || 0
      button.disabled = count === 0
      button.setAttribute("aria-pressed", this.selectedDomains.has(button.dataset.domain) ? "true" : "false")
      button.classList.toggle("opacity-30", count === 0)
    })
  }

  pruneUnavailableTraits() {
    if (this.selectedTraits.size === 0) return

    const available = new Set(this.traitsForCurrentDomain(this.traitCounts(this.rowsForStatusAndDomain())))
    this.selectedTraits.forEach((trait) => {
      if (!available.has(trait)) this.selectedTraits.delete(trait)
    })
  }

  filteredRows() {
    return this.rowsForStatusAndDomain().filter((row) => {
      const traitMatch = this.selectedTraits.size === 0 || this.effectiveTopTraits(row).some((trait) => this.selectedTraits.has(trait))
      return traitMatch && this.matchesSearch(row)
    })
  }

  rowsForStatusAndDomain() {
    if (this.selectedDomains.size === 0) return this.rowsForStatus()

    return this.rowsForStatus().filter((row) => this.effectiveDomains(row).some((domain) => this.selectedDomains.has(domain)))
  }

  rowsForStatus() {
    return this.profileRowTargets.filter((row) => {
      if (!this.status) return true
      return this.statusFlag(row, this.status)
    })
  }

  traitsForCurrentDomain(traitCounts) {
    if (this.selectedDomains.size > 0) {
      return [...this.selectedDomains]
        .flatMap((domain) => DOMAIN_STRENGTHS[domain] || [])
        .filter((trait, index, traits) => traits.indexOf(trait) === index)
    }

    return [...traitCounts.entries()]
      .filter(([, count]) => count > 0)
      .sort((a, b) => b[1] - a[1] || a[0].localeCompare(b[0]))
      .map(([trait]) => trait)
  }

  traitCounts(rows) {
    const counts = new Map()
    rows.forEach((row) => {
      this.effectiveTopTraits(row).forEach((trait) => counts.set(trait, (counts.get(trait) || 0) + 1))
    })
    return counts
  }

  statusCount(status) {
    if (status === "profiles") return this.profileRowTargets.length
    return this.profileRowTargets.filter((row) => this.statusFlag(row, status)).length
  }

  statuses(row) {
    return (row.dataset.statuses || "").split("|").filter(Boolean)
  }

  statusFlag(row, status) {
    if (status === "activeish") return row.getAttribute("data-status-activeish") === "1"
    if (status === "invite_ready") return row.getAttribute("data-status-invite-ready") === "1"
    if (status === "held") return row.getAttribute("data-status-held") === "1"
    return true
  }

  domains(row) {
    return (row.dataset.domains || "").split("|").filter(Boolean)
  }

  topTraits(row) {
    return (row.dataset.topTraits || "").split("|").filter(Boolean)
  }

  matchesSearch(row) {
    if (!this.searchQuery) return true

    return (row.dataset.searchText || row.dataset.name || "").toLowerCase().includes(this.searchQuery)
  }

  effectiveDomains(row) {
    return this.domains(this.effectiveStrengthRow(row))
  }

  effectiveTopTraits(row) {
    return this.topTraits(this.effectiveStrengthRow(row))
  }

  effectiveStrengthRow(row) {
    if (this.domains(row).length > 0 || this.topTraits(row).length > 0) return row

    const key = this.nameKey(row)
    if (!key) return row

    return this.profileRowTargets.find((candidate) => {
      return candidate !== row && this.nameKey(candidate) === key && this.topTraits(candidate).length > 0
    }) || row
  }

  nameKey(row) {
    return (row.dataset.name || "").trim().toLowerCase()
  }

  flag(row, datasetKey, attributeName = datasetKey) {
    return row.dataset[datasetKey] === "true" || row.getAttribute(`data-${attributeName}`) === "true"
  }

  compareScore(left, right) {
    for (let index = 0; index < left.length; index += 1) {
      if (left[index] > right[index]) return 1
      if (left[index] < right[index]) return -1
    }
    return 0
  }

  escapeHtml(value) {
    return String(value)
      .replaceAll("&", "&amp;")
      .replaceAll("<", "&lt;")
      .replaceAll(">", "&gt;")
      .replaceAll('"', "&quot;")
      .replaceAll("'", "&#039;")
  }
}
