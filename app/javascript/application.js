// Configure your import map in config/importmap.rb. Read more: https://github.com/rails/importmap-rails
import "@hotwired/turbo-rails"
import "controllers"

const DEAL_DETAILS_SELECTORS = [
  "[data-deal-card] .deal-info-details",
  "[data-deal-card] .deal-action-row details",
  "[data-deal-card] .comms-lab-details",
  "body > .rpt-lab-details--portaled",
  "body > .comms-lab-details--portaled",
  "body > .report-kits-details--portaled"
]
const DEAL_DETAILS_SELECTOR = DEAL_DETAILS_SELECTORS.join(", ")
const OPEN_DEAL_DETAILS_SELECTOR = DEAL_DETAILS_SELECTORS.map((selector) => `${selector}[open]`).join(", ")
const POINTER_CLOSE_DELAY = 320
const closeTimers = new WeakMap()
const reportPortalState = new WeakMap()
const commsPrepPollers = new Map()
const COMMS_PREP_STORAGE_PREFIX = "wizwiki:comms-prep:"
const COMMS_PREP_MAX_AGE = 45 * 1000
const COMMS_WIN_MENU_SELECTOR = "[data-comms-win-menu]"
const COMMS_WIN_MENU_TRIGGER_SELECTOR = "[data-comms-win-menu-trigger]"
const COMMS_EMAIL_FOLLOWUP_SELECTOR = ".comms-command-email-followup"
const COMMS_WIN_MENU_CLOSE_DELAY = 180
const commsWinMenuCloseTimers = new WeakMap()
let lastPointerPosition = null

function setCommsWinMenuOpen(menu, open) {
  if (!(menu instanceof HTMLElement)) return

  menu.classList.toggle("is-open", open)
  const trigger = menu.querySelector(COMMS_WIN_MENU_TRIGGER_SELECTOR)
  if (trigger instanceof HTMLElement) trigger.setAttribute("aria-expanded", open ? "true" : "false")

  if (open) return
  menu.querySelectorAll(`${COMMS_EMAIL_FOLLOWUP_SELECTOR}[open]`).forEach((details) => {
    if (details instanceof HTMLDetailsElement) details.open = false
  })
}

function cancelCommsWinMenuClose(menu) {
  const timer = commsWinMenuCloseTimers.get(menu)
  if (timer) window.clearTimeout(timer)
  commsWinMenuCloseTimers.delete(menu)
}

function closeCommsWinMenus(except = null) {
  document.querySelectorAll(COMMS_WIN_MENU_SELECTOR).forEach((menu) => {
    if (menu === except) return

    cancelCommsWinMenuClose(menu)
    setCommsWinMenuOpen(menu, false)
    blurCommsWinMenuFocus(menu)
  })
}

function blurCommsWinMenuFocus(menu) {
  const active = document.activeElement
  if (active instanceof HTMLElement && menu?.contains(active)) active.blur()
}

function installCommsWinMenus(root = document) {
  root.querySelectorAll(COMMS_WIN_MENU_SELECTOR).forEach((menu) => {
    if (menu.dataset.commsWinBound === "true") return
    menu.dataset.commsWinBound = "true"
    setCommsWinMenuOpen(menu, false)

    const openMenu = () => {
      cancelCommsWinMenuClose(menu)
      closeCommsWinMenus(menu)
      setCommsWinMenuOpen(menu, true)
    }

    const scheduleMenuClose = () => {
      cancelCommsWinMenuClose(menu)
      const timer = window.setTimeout(() => {
        commsWinMenuCloseTimers.delete(menu)
        if (menu.matches(":hover") || menu.matches(":focus-within")) return
        setCommsWinMenuOpen(menu, false)
        blurCommsWinMenuFocus(menu)
      }, COMMS_WIN_MENU_CLOSE_DELAY)
      commsWinMenuCloseTimers.set(menu, timer)
    }

    menu.addEventListener("mouseenter", openMenu)
    menu.addEventListener("mouseleave", scheduleMenuClose)
    menu.addEventListener("focusin", openMenu)
    menu.addEventListener("focusout", scheduleMenuClose)

    menu.querySelectorAll(COMMS_EMAIL_FOLLOWUP_SELECTOR).forEach((details) => {
      if (!(details instanceof HTMLDetailsElement)) return
      if (details.dataset.commsEmailHoverBound === "true") return
      details.dataset.commsEmailHoverBound = "true"

      const openEmailFollowup = () => {
        menu.querySelectorAll(`${COMMS_EMAIL_FOLLOWUP_SELECTOR}[open]`).forEach((other) => {
          if (other instanceof HTMLDetailsElement && other !== details) other.open = false
        })
        details.open = true
      }

      const closeEmailFollowup = () => {
        window.setTimeout(() => {
          if (details.matches(":hover") || details.matches(":focus-within")) return
          details.open = false
        }, 80)
      }

      details.addEventListener("mouseenter", openEmailFollowup)
      details.addEventListener("focusin", openEmailFollowup)
      details.addEventListener("mouseleave", closeEmailFollowup)
      details.addEventListener("focusout", closeEmailFollowup)
    })
  })
}

function handleCommsWinMenuClick(event) {
  const target = event.target instanceof Element ? event.target : null
  if (!target) return false

  const trigger = target.closest(COMMS_WIN_MENU_TRIGGER_SELECTOR)
  if (trigger) {
    const menu = trigger.closest(COMMS_WIN_MENU_SELECTOR)
    if (!menu) return false
    event.preventDefault()
    event.stopPropagation()
    const willOpen = menu.matches(":hover") || menu.matches(":focus-within") || !menu.classList.contains("is-open")
    closeCommsWinMenus(menu)
    cancelCommsWinMenuClose(menu)
    setCommsWinMenuOpen(menu, willOpen)
    return true
  }

  if (!target.closest(COMMS_WIN_MENU_SELECTOR)) closeCommsWinMenus()
  return false
}

function dealQueueFrameUrl() {
  return `${window.location.pathname}${window.location.search}`
}

function refreshDealQueueFrames() {
  const url = dealQueueFrameUrl()
  ;["deal_queue_stats", "deal_queue_processing_bay", "deal_queue_results"].forEach((id) => {
    const frame = document.getElementById(id)
    if (!frame || frame.tagName !== "TURBO-FRAME") return
    frame.src = url
    frame.reload?.()
  })
}

function commsPrepStorageKey(dealId) {
  return `${COMMS_PREP_STORAGE_PREFIX}${dealId}`
}

function commsPrepLauncherForDeal(dealId) {
  if (!dealId) return false
  const escapedDealId = window.CSS?.escape ? CSS.escape(String(dealId)) : String(dealId).replace(/[^a-zA-Z0-9_-]/g, "\\$&")
  return document.querySelector(`#deal-card-${escapedDealId} [data-open-comms-lab-id]`)
}

function openCommsLabById(labId) {
  if (!labId) return false

  const details = document.getElementById(labId)
  if (!(details instanceof HTMLDetailsElement)) return false

  closeOpenDealDetails(document, details)
  details.open = true
  portalReportDetails(details)
  window.setTimeout(() => {
    const field = details.querySelector(".comms-lab-editor textarea, .comms-lab-editor input[type='text'], .comms-lab-submit")
    if (field instanceof HTMLElement) field.focus({ preventScroll: true })
  }, 60)
  return true
}

function openPreparedCommsLab(dealId) {
  const launcher = commsPrepLauncherForDeal(dealId)
  const labId = launcher?.dataset?.openCommsLabId
  return openCommsLabById(labId)
}

function clearCommsPrepPolling(dealId) {
  const key = String(dealId)
  const poller = commsPrepPollers.get(key)
  if (poller) window.clearInterval(poller)
  commsPrepPollers.delete(key)
  try {
    window.sessionStorage?.removeItem(commsPrepStorageKey(key))
  } catch (_) {
  }
}

function startCommsPrepPolling(dealId) {
  const key = String(dealId || "")
  if (!key || commsPrepPollers.has(key)) return

  const tick = () => {
    let pending = null
    try {
      const raw = window.sessionStorage?.getItem(commsPrepStorageKey(key))
      pending = raw ? JSON.parse(raw) : null
    } catch (_) {
      pending = null
    }

    const startedAt = Number(pending?.startedAt || 0)
    const expired = !startedAt || Date.now() - startedAt > COMMS_PREP_MAX_AGE
    if (expired) {
      clearCommsPrepPolling(key)
      return
    }

    if (openPreparedCommsLab(key)) {
      clearCommsPrepPolling(key)
      return
    }

    refreshDealQueueFrames()
  }

  commsPrepPollers.set(key, window.setInterval(tick, 2500))
  window.setTimeout(tick, 1000)
}

function restoreCommsPrepPolling() {
  try {
    for (let index = 0; index < window.sessionStorage.length; index += 1) {
      const storageKey = window.sessionStorage.key(index)
      if (!storageKey?.startsWith(COMMS_PREP_STORAGE_PREFIX)) continue
      startCommsPrepPolling(storageKey.slice(COMMS_PREP_STORAGE_PREFIX.length))
    }
  } catch (_) {
  }
}

const THUMPER_SMS_LIVE_RUNTIME_VERSION = "2026-06-22.7"
const THUMPER_SMS_LEGACY_LIVE_ENABLED = true
window.__thumperSmsLiveRuntimeVersion = THUMPER_SMS_LIVE_RUNTIME_VERSION

const THUMPER_SMS_LIVE_ROW_SELECTOR = ".comms-command-row[data-comms-station-url-value]"
const THUMPER_SMS_LIVE_PATCH_SELECTORS = [
  ".comms-command-chatlog",
  ".comms-command-live-progress",
  ".comms-command-processing-strip",
  ".comms-command-location-strip",
  ".comms-command-phone-status",
  ".comms-command-callblock-banner",
  ".comms-command-card-status",
  ".comms-command-contact-snapshot",
  ".comms-command-discovery-strip",
  ".comms-command-draft-meta",
]
const thumperSmsLiveState = {
  started: false,
  inFlight: new Set(),
  progressTimers: new Map(),
  backgroundPolls: new Map(),
  timer: null,
}
const THUMPER_SMS_BACKGROUND_POLL_MS = 6000

function thumperSmsStageId(row) {
  return row?.dataset?.commsStationStageIdValue || row?.id?.replace(/^stage-/, "") || ""
}

function thumperSmsOpenStageParam() {
  try {
    return new URL(window.location.href).searchParams.get("open_sms_stage") || ""
  } catch (_) {
    return ""
  }
}

function thumperSmsShouldPoll(row) {
  if (!(row instanceof Element)) return false
  const stageId = thumperSmsStageId(row)
  const paramOpen = stageId && thumperSmsOpenStageParam() === stageId
  const overlayOpen = !!row.querySelector(".comms-command-details[open] .comms-command-communicator--phone")
  return overlayOpen || paramOpen || row.dataset.commsStationWatchValue === "true"
}

function thumperSmsRowNearViewport(row) {
  if (!(row instanceof Element)) return false
  const rect = row.getBoundingClientRect()
  const pad = Math.max(window.innerHeight || 0, 900)
  return rect.bottom >= -pad && rect.top <= (window.innerHeight || 0) + pad
}

function thumperSmsShouldBackgroundPoll(row) {
  if (!(row instanceof Element)) return false
  if (document.hidden) return false
  if (thumperSmsShouldPoll(row)) return false
  if (!thumperSmsRowNearViewport(row)) return false
  if (!row.classList.contains("comms-command-row--listening") &&
    !row.classList.contains("comms-command-row--autopilot") &&
    !row.classList.contains("comms-command-row--drafting") &&
    !row.classList.contains("comms-command-row--callblock") &&
    !row.classList.contains("comms-command-row--new-inbound")) return false

  const key = row.id || thumperSmsStageId(row)
  if (!key) return false
  const last = thumperSmsLiveState.backgroundPolls.get(key) || 0
  if (Date.now() - last < THUMPER_SMS_BACKGROUND_POLL_MS) return false

  thumperSmsLiveState.backgroundPolls.set(key, Date.now())
  return true
}

function thumperSmsSetOpenStageParam(row) {
  const stageId = thumperSmsStageId(row)
  if (!stageId) return

  try {
    const url = new URL(window.location.href)
    url.searchParams.set("open_sms_stage", stageId)
    url.searchParams.delete("open_email_stage")
    url.hash = `stage-${stageId}`
    window.history.replaceState(window.history.state, "", `${url.pathname}${url.search}${url.hash}`)
  } catch (_) {
  }
}

function thumperSmsOpenRow(row, details = null) {
  if (!(row instanceof Element)) return
  const targetDetails = details instanceof HTMLDetailsElement ?
    details :
    row.querySelector(".comms-command-details")
  if (targetDetails instanceof HTMLDetailsElement) targetDetails.open = true

  row.dataset.commsStationWatchValue = "true"
  thumperSmsSetOpenStageParam(row)
  thumperSmsScrollToBottom(row)
  window.setTimeout(() => pollThumperSmsRow(row), 0)
  window.setTimeout(() => pollThumperSmsRow(row), 160)
  window.setTimeout(() => pollThumperSmsRow(row), 700)
}

function thumperSmsLiveUrl(row) {
  const rawUrl = row?.dataset?.commsStationUrlValue
  if (!rawUrl) return null

  try {
    const url = new URL(rawUrl, window.location.origin)
    url.searchParams.set("_live_at", Date.now().toString())
    return url.toString()
  } catch (_) {
    return rawUrl
  }
}

function thumperSmsChatBottomState(row) {
  const chatlog = row?.querySelector(".comms-command-communicator--phone .comms-command-chatlog")
  if (!chatlog) return { shouldStick: true, top: 0, bottomGap: 0 }

  const bottomGap = chatlog.scrollHeight - chatlog.scrollTop - chatlog.clientHeight

  return {
    shouldStick: bottomGap <= 80,
    top: chatlog.scrollTop,
    bottomGap,
  }
}

function thumperSmsScrollToBottom(row) {
  const run = () => {
    const chatlog = row?.querySelector(".comms-command-communicator--phone .comms-command-chatlog")
    if (!chatlog) return

    const progress = chatlog.querySelector(".comms-command-draft-progress--active, .comms-command-draft-progress.is-live, .comms-command-draft-progress[data-autos-progress-active='true']")
    const latestEnd = chatlog.querySelector(".comms-command-chat-latest-end")
    const latest = Array.from(chatlog.querySelectorAll(".comms-command-bubble, .comms-command-empty")).at(-1)
    const target = latestEnd || latest || chatlog.querySelector(".comms-command-chat-end") || progress
    if (target?.scrollIntoView) {
      target.scrollIntoView({ block: "end", inline: "nearest" })
      const chatRect = chatlog.getBoundingClientRect()
      const targetRect = target.getBoundingClientRect()
      const bottomDelta = targetRect.bottom - chatRect.bottom
      if (Math.abs(bottomDelta) > 1) chatlog.scrollTop += bottomDelta
      return
    }

    chatlog.scrollTop = chatlog.scrollHeight
    chatlog.scrollTo?.({ top: chatlog.scrollHeight, behavior: "auto" })
  }

  run()
  window.requestAnimationFrame(run)
  window.requestAnimationFrame(() => window.requestAnimationFrame(run))
  window.setTimeout(run, 80)
  window.setTimeout(run, 220)
}

function thumperSmsRestoreChatScroll(row, bottomState) {
  const chatlog = row?.querySelector(".comms-command-communicator--phone .comms-command-chatlog")
  if (!chatlog) return

  if (!bottomState || bottomState.shouldStick) {
    thumperSmsScrollToBottom(row)
    return
  }

  const restoreTop = () => {
    chatlog.scrollTop = Math.max(0, Math.min(bottomState.top || 0, chatlog.scrollHeight - chatlog.clientHeight))
  }

  restoreTop()
  window.requestAnimationFrame(restoreTop)
  window.setTimeout(restoreTop, 80)
  window.setTimeout(restoreTop, 220)
}

function thumperSmsNodeShowsDrafting(node) {
  if (!(node instanceof Element)) return false

  return node.classList.contains("comms-command-row--drafting") ||
    !!node.querySelector(".comms-command-row--drafting, .comms-command-draft-progress--active, .comms-command-draft-progress.is-live, .comms-command-draft-progress[data-autos-progress-active='true']")
}

function thumperSmsProgressStartedAt(row) {
  const progress = row?.querySelector(".comms-command-draft-progress--active, .comms-command-draft-progress.is-live, .comms-command-draft-progress[data-autos-progress-active='true'], .comms-command-draft-progress")
  const parsed = Date.parse(progress?.dataset?.thumperProgressStartedAt || "")
  return Number.isNaN(parsed) ? Date.now() : parsed
}

function thumperSmsSetProgressTimerText(row, text) {
  row?.querySelectorAll("[data-comms-station-target~='progressTimer'], .comms-command-draft-progress-timer").forEach((node) => {
    node.textContent = text
  })
}

function thumperSmsDraftKey(row) {
  const field = row?.querySelector("textarea[name='sms_body']")
  if (field instanceof HTMLTextAreaElement || field instanceof HTMLInputElement) {
    return field.dataset?.thumperDraftKey || field.value || ""
  }

  return ""
}

function thumperSmsTickProgress(row, startedAt) {
  const elapsed = Math.max(0, Math.floor((Date.now() - startedAt) / 1000))
  const minutes = Math.floor(elapsed / 60).toString().padStart(2, "0")
  const seconds = (elapsed % 60).toString().padStart(2, "0")
  thumperSmsSetProgressTimerText(row, `${minutes}:${seconds}`)
}

function thumperSmsEnsureProgressTimer(row) {
  if (!(row instanceof Element)) return

  const key = row.id || thumperSmsStageId(row)
  if (!key) return

  const existing = thumperSmsLiveState.progressTimers.get(key)
  const startedAt = existing?.startedAt || thumperSmsProgressStartedAt(row)
  const draftKey = existing?.draftKey || thumperSmsDraftKey(row)
  if (existing?.timer) window.clearInterval(existing.timer)

  row.querySelectorAll(".comms-command-draft-progress").forEach((node) => {
    node.classList.add("comms-command-draft-progress--active", "is-live")
    node.dataset.thumperProgressActive = "true"
    node.setAttribute("aria-busy", "true")
    node.querySelectorAll(".comms-command-draft-progress-bar span").forEach((span) => {
      span.style.width = "62%"
      span.style.opacity = "1"
      span.style.animation = "commsLiveRun 0.92s linear infinite, commsRainbowShift 0.52s linear infinite"
    })
  })
  thumperSmsTickProgress(row, startedAt)
  const timer = window.setInterval(() => {
    const currentRow = document.getElementById(row.id)
    if (currentRow) thumperSmsTickProgress(currentRow, startedAt)
  }, 1000)
  thumperSmsLiveState.progressTimers.set(key, { startedAt, timer, draftKey })
}

function thumperSmsShouldKeepClientProgress(row) {
  const key = row?.id || thumperSmsStageId(row)
  const existing = key ? thumperSmsLiveState.progressTimers.get(key) : null
  if (!existing?.startedAt) return false
  if (Date.now() - existing.startedAt > 3 * 60 * 1000) return false

  const currentDraftKey = thumperSmsDraftKey(row)
  if (existing.draftKey && currentDraftKey && existing.draftKey !== currentDraftKey) return false

  return true
}

function thumperSmsPrimeDraftProgress(source, message = "Thumper drafting next text") {
  const origin = source instanceof Element ? source : null
  const row = origin?.closest(THUMPER_SMS_LIVE_ROW_SELECTOR)
  if (!(row instanceof Element)) return

  const key = row.id || thumperSmsStageId(row)
  const startedAt = Date.now()
  row.dataset.commsStationWatchValue = "true"
  row.classList.add("comms-command-row--busy", "comms-command-row--draft-clicking")
  row.querySelectorAll(".comms-command-communicator--phone").forEach((phone) => {
    phone.classList.add("comms-command-communicator--drafting")
    phone.dataset.thumperDrafting = "true"
  })
  row.querySelectorAll(".comms-command-draft-progress").forEach((node) => {
    node.classList.add("comms-command-draft-progress--active", "is-live")
    node.dataset.thumperProgressActive = "true"
    node.dataset.thumperProgressStartedAt = new Date(startedAt).toISOString()
    node.setAttribute("aria-busy", "true")
    node.querySelectorAll(".comms-command-draft-progress-bar span").forEach((span) => {
      span.style.width = "62%"
      span.style.opacity = "1"
      span.style.animation = "commsLiveRun 0.92s linear infinite, commsRainbowShift 0.52s linear infinite"
    })
  })
  row.querySelectorAll("[data-comms-station-target~='progressMessage'], .comms-command-draft-progress-active").forEach((node) => {
    if (node.classList.contains("comms-command-draft-progress-timer")) return
    node.textContent = message
  })

  const draftKey = thumperSmsDraftKey(row)
  const existing = key ? thumperSmsLiveState.progressTimers.get(key) : null
  if (existing?.timer) window.clearInterval(existing.timer)
  thumperSmsTickProgress(row, startedAt)
  if (key) {
    const timer = window.setInterval(() => {
      const currentRow = document.getElementById(row.id)
      if (currentRow) thumperSmsTickProgress(currentRow, startedAt)
    }, 1000)
    thumperSmsLiveState.progressTimers.set(key, { startedAt, timer, draftKey })
  }
  thumperSmsScrollToBottom(row)
  window.setTimeout(pollOpenThumperSmsStations, 180)
  window.setTimeout(pollOpenThumperSmsStations, 900)
}

function thumperSmsStopProgressTimer(row) {
  const key = row?.id || thumperSmsStageId(row)
  if (!key) return

  const existing = thumperSmsLiveState.progressTimers.get(key)
  if (existing?.timer) window.clearInterval(existing.timer)
  thumperSmsLiveState.progressTimers.delete(key)

  row?.querySelectorAll(".comms-command-draft-progress").forEach((node) => {
    node.classList.remove("comms-command-draft-progress--active", "is-live")
    delete node.dataset.thumperProgressActive
    node.removeAttribute("aria-busy")
    node.querySelectorAll(".comms-command-draft-progress-bar span").forEach((span) => {
      span.style.width = ""
      span.style.opacity = ""
      span.style.animation = ""
    })
  })
  thumperSmsSetProgressTimerText(row, "00:00")
}

function thumperSmsCopyFormValue(row, next, selector) {
  const currentNode = row.querySelector(selector)
  const nextNode = next.querySelector(selector)
  const currentEditable = currentNode instanceof HTMLTextAreaElement || currentNode instanceof HTMLInputElement
  const nextEditable = nextNode instanceof HTMLTextAreaElement || nextNode instanceof HTMLInputElement
  if (!currentEditable || !nextEditable) return
  const draftChanged = selector === "textarea[name='sms_body']" &&
    nextNode.dataset.thumperDraftKey &&
    currentNode.dataset.thumperDraftKey !== nextNode.dataset.thumperDraftKey
  if (currentNode === document.activeElement && currentNode.value !== currentNode.defaultValue && !draftChanged) return

  currentNode.value = nextNode.value
  currentNode.defaultValue = nextNode.value
  Object.keys(nextNode.dataset || {}).forEach((key) => {
    currentNode.dataset[key] = nextNode.dataset[key]
  })
}

function thumperSmsPatchRowFromHtml(row, html, bottomState) {
  if (!(row instanceof Element)) return

  const documentFragment = new DOMParser().parseFromString(html, "text/html")
  const stageId = thumperSmsStageId(row)
  const escapedStageId = window.CSS?.escape ? CSS.escape(stageId) : stageId
  const next = documentFragment.getElementById(row.id) ||
    (stageId ? documentFragment.querySelector(`[data-comms-station-stage-id-value='${escapedStageId}']`) : null)
  if (!next) return
  const serverDrafting = thumperSmsNodeShowsDrafting(next)

  const openIndexes = Array.from(row.querySelectorAll(".comms-command-details"))
    .map((details, index) => details instanceof HTMLDetailsElement && details.open ? index : null)
    .filter((index) => index !== null)

  row.className = next.className
  if (next.dataset.commsStationVersionValue) {
    row.dataset.commsStationVersionValue = next.dataset.commsStationVersionValue
  }

  const currentPhone = row.querySelector(".comms-command-details[open] .comms-command-communicator--phone")
  const nextPhone = next.querySelector(".comms-command-details[open] .comms-command-communicator--phone")
  if (currentPhone?.dataset?.commsLazyStation === "true" && nextPhone) {
    currentPhone.replaceWith(nextPhone)
  }

  THUMPER_SMS_LIVE_PATCH_SELECTORS.forEach((selector) => {
    const currentNode = row.querySelector(selector)
    const nextNode = next.querySelector(selector)
    if (!currentNode || !nextNode) return
    currentNode.replaceWith(nextNode)
  })

  thumperSmsCopyFormValue(row, next, "textarea[name='sms_body']")
  thumperSmsCopyFormValue(row, next, "textarea[name='sms_prompt']")

  openIndexes.forEach((index) => {
    const details = row.querySelectorAll(".comms-command-details")[index]
    if (details instanceof HTMLDetailsElement) details.open = true
  })

  thumperSmsRestoreChatScroll(row, bottomState)

  if (serverDrafting) {
    thumperSmsEnsureProgressTimer(row)
  } else {
    thumperSmsStopProgressTimer(row)
  }
}

async function pollThumperSmsRow(row) {
  const url = thumperSmsLiveUrl(row)
  const requestKey = row.id || thumperSmsStageId(row) || url
  if (!url || thumperSmsLiveState.inFlight.has(requestKey)) return

  const bottomState = thumperSmsChatBottomState(row)
  thumperSmsLiveState.inFlight.add(requestKey)
  try {
    const response = await fetch(url, {
      credentials: "same-origin",
      cache: "no-store",
      headers: {
        "Accept": "text/html",
        "Cache-Control": "no-cache",
        "X-Requested-With": "XMLHttpRequest",
      },
    })
    if (!response.ok) return
    const html = await response.text()
    thumperSmsPatchRowFromHtml(row, html, bottomState)
  } catch (_) {
    // Live SMS refresh is a soft repaint path. The next poll can recover.
  } finally {
    thumperSmsLiveState.inFlight.delete(requestKey)
  }
}

function pollOpenThumperSmsStations() {
  document.querySelectorAll(THUMPER_SMS_LIVE_ROW_SELECTOR).forEach((row) => {
    if (row.querySelector(".comms-command-details[open] .comms-command-communicator--phone")) {
      row.dataset.commsStationWatchValue = "true"
    }
    if (thumperSmsShouldPoll(row) || thumperSmsShouldBackgroundPoll(row)) pollThumperSmsRow(row)
  })
}

function scrollOpenThumperSmsStations() {
  clampThumperSmsOverlays()
  document.querySelectorAll(THUMPER_SMS_LIVE_ROW_SELECTOR).forEach((row) => {
    if (thumperSmsShouldPoll(row)) thumperSmsScrollToBottom(row)
  })
  window.requestAnimationFrame(() => clampThumperSmsOverlays())
}

function clampThumperSmsOverlays(scope = document) {
  const root = scope instanceof Element || scope instanceof Document ? scope : document
  root.querySelectorAll(".comms-command-details[open] .comms-command-communicator--phone").forEach((panel) => {
    if (!(panel instanceof HTMLElement)) return

    panel.style.setProperty("--sms-overlay-nudge-x", "0px")
    panel.style.setProperty("--sms-overlay-nudge-y", "0px")

    const rect = panel.getBoundingClientRect()
    if (!rect.width || !rect.height) return

    const margin = 8
    let dx = 0
    let dy = 0

    if (rect.left < margin) dx += margin - rect.left
    if (rect.right + dx > window.innerWidth - margin) dx -= rect.right + dx - (window.innerWidth - margin)
    if (rect.top < margin) dy += margin - rect.top
    if (rect.bottom + dy > window.innerHeight - margin) dy -= rect.bottom + dy - (window.innerHeight - margin)

    panel.style.setProperty("--sms-overlay-nudge-x", `${Math.round(dx)}px`)
    panel.style.setProperty("--sms-overlay-nudge-y", `${Math.round(dy)}px`)
  })
}

function installThumperConfirmGuard() {
  if (window.__thumperConfirmGuardInstalled) return
  window.__thumperConfirmGuardInstalled = true

  const confirmMessageFor = (form, submitter = null) => {
    return submitter?.dataset?.commsConfirmMessage ||
      submitter?.dataset?.turboConfirm ||
      form?.dataset?.commsConfirmMessage ||
      form?.dataset?.turboConfirm ||
      null
  }

  const suppressTurboConfirm = (form, submitter = null) => {
    if (form?.dataset) delete form.dataset.turboConfirm
    if (submitter?.dataset) delete submitter.dataset.turboConfirm
  }

  document.addEventListener("submit", (event) => {
    const form = event.target
    if (!(form instanceof HTMLFormElement)) return

    const message = confirmMessageFor(form, event.submitter)
    if (!message) return

    if (form.dataset.commsConfirmed === "true") {
      suppressTurboConfirm(form, event.submitter)
      window.setTimeout(() => {
        delete form.dataset.commsConfirmed
      }, 0)
      return
    }

    if (window.confirm(message)) {
      form.dataset.commsConfirmed = "true"
      suppressTurboConfirm(form, event.submitter)
      return
    }

    event.preventDefault()
    event.stopPropagation()
    event.stopImmediatePropagation?.()
  }, true)

  document.addEventListener("click", (event) => {
    const submitter = event.target instanceof Element ? event.target.closest("button, input[type='submit']") : null
    if (!(submitter instanceof HTMLElement)) return

    const form = submitter.form
    if (!(form instanceof HTMLFormElement)) return

    const message = confirmMessageFor(form, submitter)
    if (!message) return
    if (form.dataset.commsConfirmed === "true") {
      suppressTurboConfirm(form, submitter)
      return
    }

    event.preventDefault()
    event.stopPropagation()
    event.stopImmediatePropagation?.()

    if (!window.confirm(message)) return

    form.dataset.commsConfirmed = "true"
    suppressTurboConfirm(form, submitter)
    form.requestSubmit(submitter)
  }, true)
}

function installThumperSmsProgressGuard() {
  if (window.__thumperSmsProgressGuardInstalled) return
  window.__thumperSmsProgressGuardInstalled = true

  const draftFormFor = (target) => {
    if (target instanceof HTMLFormElement) return target
    const button = target instanceof Element ? target.closest(".comms-command-send--rewrite") : null
    return button?.closest("form")
  }

  const shouldPrime = (form, target = null) => {
    if (!(form instanceof HTMLFormElement)) return false
    if (!form.closest(".comms-command-communicator--phone")) return false
    const text = `${form.action || ""} ${target?.textContent || target?.value || ""}`.toLowerCase()
    return text.includes("/sms/draft") || text.includes("generate next text")
  }

  const primeFromEvent = (event) => {
    const target = event.target instanceof Element || event.target instanceof HTMLFormElement ? event.target : null
    const form = draftFormFor(target)
    if (!shouldPrime(form, target)) return
    thumperSmsPrimeDraftProgress(form, "Thumper drafting next text")
  }

  document.addEventListener("pointerdown", primeFromEvent, true)
  document.addEventListener("touchstart", primeFromEvent, { capture: true, passive: true })
  document.addEventListener("click", primeFromEvent, true)
  document.addEventListener("submit", primeFromEvent, true)
}

function startThumperSmsLivePolling() {
  if (thumperSmsLiveState.started) {
    scrollOpenThumperSmsStations()
    window.setTimeout(pollOpenThumperSmsStations, 120)
    return
  }

  thumperSmsLiveState.started = true
  thumperSmsLiveState.timer = window.setInterval(pollOpenThumperSmsStations, 1800)
  scrollOpenThumperSmsStations()
  window.setTimeout(pollOpenThumperSmsStations, 250)
  window.setTimeout(scrollOpenThumperSmsStations, 80)
  window.setTimeout(scrollOpenThumperSmsStations, 280)
  window.setTimeout(scrollOpenThumperSmsStations, 720)

  document.addEventListener("toggle", (event) => {
    const details = event.target
    if (!(details instanceof HTMLDetailsElement) || !details.open) return
    if (!details.querySelector(".comms-command-communicator--phone")) return

    const row = details.closest(THUMPER_SMS_LIVE_ROW_SELECTOR)
	  if (row instanceof Element) {
	      thumperSmsOpenRow(row, details)
	    }
	    window.setTimeout(pollOpenThumperSmsStations, 120)
	    window.setTimeout(scrollOpenThumperSmsStations, 160)
	    window.setTimeout(clampThumperSmsOverlays, 220)
	  }, true)

  document.addEventListener("click", (event) => {
    const summary = event.target instanceof Element ? event.target.closest(".comms-command-icon-button--sms") : null
    if (!summary) return
    const row = summary.closest(THUMPER_SMS_LIVE_ROW_SELECTOR)
    const details = summary.closest(".comms-command-details")
    if (!(row instanceof Element) || !(details instanceof HTMLDetailsElement)) return

    event.preventDefault()
    event.stopPropagation()
    event.stopImmediatePropagation?.()
    thumperSmsOpenRow(row, details)
  }, true)

	  document.addEventListener("visibilitychange", () => {
	    if (!document.hidden) window.setTimeout(pollOpenThumperSmsStations, 120)
	  })

	  window.addEventListener("resize", () => {
	    window.requestAnimationFrame(() => clampThumperSmsOverlays())
	  })
	}

function dealDetailsFor(node) {
  return node instanceof Element ? node.closest(DEAL_DETAILS_SELECTOR) : null
}

function flyoutFor(details) {
  return details.querySelector(":scope > .deal-flyout") || details.querySelector(".deal-flyout")
}

function isReportFlyout(flyout) {
  return flyout?.classList.contains("deal-flyout--report") || flyout?.classList.contains("report-kits-overlay")
}

function isReportDetails(details) {
  return isReportFlyout(flyoutFor(details))
}

function reportPortalClassFor(details) {
  if (details?.classList?.contains("report-kits-details")) return "report-kits-details--portaled"
  return details?.classList?.contains("comms-lab-details") ? "comms-lab-details--portaled" : "rpt-lab-details--portaled"
}

function summaryFor(details) {
  return details.querySelector(":scope > summary")
}

function expandedRect(rect, padding = 10) {
  return {
    left: rect.left - padding,
    right: rect.right + padding,
    top: rect.top - padding,
    bottom: rect.bottom + padding,
  }
}

function pointWithinRect(point, rect, padding = 10) {
  if (!point || !rect) return false

  const expanded = expandedRect(rect, padding)
  return point.x >= expanded.left && point.x <= expanded.right && point.y >= expanded.top && point.y <= expanded.bottom
}

function pointWithinBridge(point, firstRect, secondRect) {
  if (!point || !firstRect || !secondRect) return false

  const bridge = {
    left: Math.min(firstRect.left, secondRect.left) - 14,
    right: Math.max(firstRect.right, secondRect.right) + 14,
    top: Math.min(firstRect.top, secondRect.top) - 14,
    bottom: Math.max(firstRect.bottom, secondRect.bottom) + 14,
  }

  return point.x >= bridge.left && point.x <= bridge.right && point.y >= bridge.top && point.y <= bridge.bottom
}

function pointWithinDealKeepZone(details, point = lastPointerPosition) {
  if (!(details instanceof HTMLDetailsElement) || !point) return false

  const flyout = flyoutFor(details)
  const summary = summaryFor(details)
  const detailsRect = details.getBoundingClientRect()
  const flyoutRect = flyout?.getBoundingClientRect()
  const summaryRect = summary?.getBoundingClientRect()

  if (isReportFlyout(flyout)) {
    return (
      pointWithinRect(point, summaryRect || detailsRect, 14) ||
      pointWithinRect(point, flyoutRect, 14)
    )
  }

  return (
    pointWithinRect(point, detailsRect, 8) ||
    pointWithinRect(point, summaryRect, 14) ||
    pointWithinRect(point, flyoutRect, 14) ||
    pointWithinBridge(point, summaryRect || detailsRect, flyoutRect)
  )
}

function cancelDealClose(details) {
  const timer = closeTimers.get(details)
  if (!timer) return

  window.clearTimeout(timer)
  closeTimers.delete(details)
}

function closeDealDetails(details) {
  if (!(details instanceof HTMLDetailsElement)) return

  cancelDealClose(details)

  const active = document.activeElement
  if (active instanceof HTMLElement && details.contains(active) && !active.closest(".deal-flyout")) {
    active.blur()
  }

  details.open = false
}

function emailSchedulerDetailsFor(source) {
  return source instanceof Element ? source.closest(".comms-command-email-followup") : null
}

function closeEmailScheduler(source) {
  const details = emailSchedulerDetailsFor(source)
  if (details instanceof HTMLDetailsElement) details.open = false
}

function emailSchedulerPanelFor(source) {
  return source instanceof Element ? source.closest("[data-email-followup-panel]") : null
}

function emailSchedulerPresets(panel) {
  try {
    return JSON.parse(panel?.dataset?.emailFollowupPresets || "{}")
  } catch (_) {
    return {}
  }
}

function fillEmailSchedulerPreset(select) {
  const panel = emailSchedulerPanelFor(select)
  if (!panel) return

  const presets = emailSchedulerPresets(panel)
  const enabled = select.value !== "off"
  const monthly = select.value === "monthly"
  const plan = enabled ? (presets[select.value] || {}) : (presets.off || {})
  panel.querySelectorAll("[data-email-followup-day]").forEach((field) => {
    field.value = plan[field.dataset.emailFollowupDay] || "none"
  })

  panel.querySelectorAll("[data-email-followup-monthly-only]").forEach((node) => {
    node.hidden = !monthly
    node.dataset.emailFollowupMonthlyActive = monthly ? "true" : "false"
  })

  if (monthly) {
    const weeks = Array.from(panel.querySelectorAll("[data-email-followup-week]"))
    if (!weeks.some((field) => field.checked)) {
      weeks.slice(0, 4).forEach((field) => {
        field.checked = true
      })
    }
  }

  const enabledField = panel.querySelector("[data-email-followup-enabled]")
  if (enabledField) enabledField.value = enabled ? "1" : "0"
  const cadence = panel.querySelector("[data-email-followup-cadence]")
  if (cadence) cadence.value = enabled ? (monthly ? "monthly" : "weekly") : "off"
  const mode = panel.querySelector("[data-email-followup-mode]")
  if (mode) mode.value = "preset"
  const badge = panel.querySelector("[data-email-followup-plan-badge]")
  if (badge) badge.textContent = enabled ? (monthly ? "MONTHLY" : "PRESET") : "OFF"
  const frequencyBadge = panel.querySelector("[data-email-followup-frequency-badge]")
  if (frequencyBadge) frequencyBadge.textContent = enabled ? (monthly ? "30 DAY" : "1/DAY") : "OFF"
}

function markEmailSchedulerCustom(select) {
  const panel = emailSchedulerPanelFor(select)
  if (!panel) return

  const mode = panel.querySelector("[data-email-followup-mode]")
  if (mode) mode.value = "custom"
  const badge = panel.querySelector("[data-email-followup-plan-badge]")
  if (badge) badge.textContent = "CUSTOM"
}

function portalReportDetails(details) {
  if (!(details instanceof HTMLDetailsElement) || reportPortalState.has(details)) return
  const portalClass = reportPortalClassFor(details)
  if (details.parentNode === document.body) {
    details.classList.add(portalClass)
    return
  }

  const originalParent = details.parentNode
  if (!originalParent) return

  const placeholder = document.createComment("rpt-lab-details-placeholder")
  const originalNextSibling = details.nextSibling
  originalParent.insertBefore(placeholder, details)
  document.body.appendChild(details)
  details.classList.add(portalClass)
  reportPortalState.set(details, { originalParent, originalNextSibling, placeholder })
}

function restoreReportDetails(details) {
  if (!(details instanceof HTMLDetailsElement)) return

  const state = reportPortalState.get(details)
  details.classList.remove("rpt-lab-details--portaled")
  details.classList.remove("comms-lab-details--portaled")
  details.classList.remove("report-kits-details--portaled")
  if (!state) return

  if (state.placeholder.parentNode === state.originalParent) {
    state.originalParent.insertBefore(details, state.placeholder)
    state.placeholder.remove()
  } else {
    state.originalParent.insertBefore(details, state.originalNextSibling)
  }

  reportPortalState.delete(details)
}

function restorePortaledReportDetails() {
  document.querySelectorAll("body > .rpt-lab-details--portaled, body > .comms-lab-details--portaled, body > .report-kits-details--portaled").forEach((details) => {
    restoreReportDetails(details)
  })
}

function closeOpenDealDetails(scope = document, except = null) {
  scope.querySelectorAll(OPEN_DEAL_DETAILS_SELECTOR).forEach((details) => {
    if (details !== except) closeDealDetails(details)
  })
}

function scheduleDealClose(details) {
  if (!(details instanceof HTMLDetailsElement) || !details.open) return
  if (isReportDetails(details)) return

  cancelDealClose(details)

  const timer = window.setTimeout(() => {
    closeTimers.delete(details)
    if (!details.open) return
    if (details.matches(":hover")) return
    if (pointWithinDealKeepZone(details)) return

    const active = document.activeElement
    const activeFlyout = active instanceof Element ? active.closest(".deal-flyout") : null
    const focusInsideFlyout = activeFlyout && details.contains(activeFlyout)
    if (focusInsideFlyout) return

    closeDealDetails(details)
  }, POINTER_CLOSE_DELAY)

  closeTimers.set(details, timer)
}

document.addEventListener("toggle", (event) => {
  const opened = event.target
  if (!(opened instanceof HTMLDetailsElement)) return

  const reportDetails = isReportDetails(opened)
  if (!opened.open) {
    if (reportDetails) restoreReportDetails(opened)
    return
  }

  cancelDealClose(opened)

  const card = opened.closest("[data-deal-card]")
  if (!card) {
    if (reportDetails) portalReportDetails(opened)
    return
  }

  const inActionRow = opened.closest(".deal-action-row")
  const isCardInfo = opened.classList.contains("deal-info-details")
  const isCommsLab = opened.classList.contains("comms-lab-details")
  if (isCommsLab) {
    portalReportDetails(opened)
    return
  }

  if (!inActionRow && !isCardInfo) return

  if (inActionRow) {
    inActionRow.querySelectorAll("details[open]").forEach((details) => {
      if (details !== opened) details.open = false
    })
  }

  if (isCardInfo) {
    card.querySelectorAll(".deal-action-row details[open]").forEach((details) => {
      closeDealDetails(details)
    })
  }

  const infoDetails = card.querySelector(".deal-info-details[open]")
  if (infoDetails && infoDetails !== opened) closeDealDetails(infoDetails)

  if (reportDetails) portalReportDetails(opened)
}, true)

// Deal card flyouts are click-to-open, but should disappear when the pointer leaves the visible flyout zone.
document.addEventListener("pointermove", (event) => {
  lastPointerPosition = { x: event.clientX, y: event.clientY }

  document.querySelectorAll(OPEN_DEAL_DETAILS_SELECTOR).forEach((details) => {
    if (isReportDetails(details)) {
      cancelDealClose(details)
      return
    }

    if (details.matches(":hover") || pointWithinDealKeepZone(details, lastPointerPosition)) {
      cancelDealClose(details)
    } else {
      scheduleDealClose(details)
    }
  })
}, true)

document.addEventListener("pointerover", (event) => {
  lastPointerPosition = { x: event.clientX, y: event.clientY }

  const details = dealDetailsFor(event.target)
  if (!(details instanceof HTMLDetailsElement)) return

  cancelDealClose(details)
}, true)

document.addEventListener("pointerout", (event) => {
  lastPointerPosition = { x: event.clientX, y: event.clientY }

  const details = dealDetailsFor(event.target)
  if (!(details instanceof HTMLDetailsElement) || !details.open) return
  if (isReportDetails(details)) return
  if (event.relatedTarget instanceof Node && details.contains(event.relatedTarget)) return
  if (pointWithinDealKeepZone(details, lastPointerPosition)) return

  scheduleDealClose(details)
}, true)

document.addEventListener("click", (event) => {
  if (handleCommsWinMenuClick(event)) return

  const emailSchedulerClose = event.target instanceof Element ? event.target.closest(".comms-command-email-followup-close, .comms-command-email-followup-backdrop") : null
  if (emailSchedulerClose) {
    event.preventDefault()
    event.stopPropagation()
    closeEmailScheduler(emailSchedulerClose)
    return
  }

  const reportKitsLauncher = event.target instanceof Element ? event.target.closest("[data-report-kits-open]") : null
  if (reportKitsLauncher) {
    event.preventDefault()
    const details = reportKitsLauncher.closest(".report-kits-details")
    if (details instanceof HTMLDetailsElement) {
      const shouldOpen = !details.open
      closeOpenDealDetails(document, shouldOpen ? details : null)
      details.open = shouldOpen
      if (shouldOpen) {
        portalReportDetails(details)
        window.setTimeout(() => {
          const close = details.querySelector("[data-close-deal-flyout]")
          if (close instanceof HTMLElement) close.focus({ preventScroll: true })
        }, 60)
      } else {
        restoreReportDetails(details)
      }
    }
    return
  }

  const closeButton = event.target instanceof Element ? event.target.closest("[data-close-deal-flyout]") : null
  if (closeButton) {
    event.preventDefault()
    event.stopPropagation()
    const details = closeButton.closest("details") || dealDetailsFor(closeButton)
    if (details instanceof HTMLDetailsElement) closeDealDetails(details)
    return
  }

  const commsLauncher = event.target instanceof Element ? event.target.closest("[data-open-comms-lab-id]") : null
  if (commsLauncher) {
    event.preventDefault()
    openCommsLabById(commsLauncher.dataset.openCommsLabId)
    return
  }

  const details = dealDetailsFor(event.target)
  if (details) {
    const clickedSummary = event.target instanceof Element && event.target.closest("summary")
    const clickedFlyout = event.target instanceof Element && event.target.closest(".deal-flyout")
    if (clickedSummary || clickedFlyout) return

    closeDealDetails(details)
    return
  }

  closeOpenDealDetails()
})

document.addEventListener("change", (event) => {
  const target = event.target instanceof Element ? event.target : null
  if (!target) return

  const preset = target.closest("[data-email-followup-preset]")
  if (preset) {
    fillEmailSchedulerPreset(preset)
    return
  }

  const day = target.closest("[data-email-followup-day]")
  if (day) markEmailSchedulerCustom(day)
}, true)

document.addEventListener("input", (event) => {
  const target = event.target instanceof Element ? event.target : null
  if (!target) return

  const preset = target.closest("[data-email-followup-preset]")
  if (preset) {
    fillEmailSchedulerPreset(preset)
    return
  }

}, true)

document.addEventListener("submit", (event) => {
  const submitter = event.submitter instanceof Element ? event.submitter : null
  const commsPrepButton = submitter?.closest("[data-comms-prep-deal-id]")
  if (!commsPrepButton) return

  const dealId = commsPrepButton.dataset.commsPrepDealId
  if (!dealId) return

  try {
    window.sessionStorage?.setItem(commsPrepStorageKey(dealId), JSON.stringify({
      dealId,
      reportId: commsPrepButton.dataset.commsPrepReportId || null,
      startedAt: Date.now()
    }))
  } catch (_) {
  }
  startCommsPrepPolling(dealId)
}, true)

document.addEventListener("keydown", (event) => {
  if (event.key !== "Escape") return
  closeCommsWinMenus()
  document.querySelectorAll(".comms-command-email-followup[open]").forEach((details) => {
    if (details instanceof HTMLDetailsElement) details.open = false
  })
  closeOpenDealDetails()
})

document.addEventListener("turbo:before-cache", () => {
  closeCommsWinMenus()
  restorePortaledReportDetails()
})
function bootThumperLiveRuntime() {
  installCommsWinMenus()
  restoreCommsPrepPolling()
  installThumperConfirmGuard()
  if (THUMPER_SMS_LEGACY_LIVE_ENABLED) {
    installThumperSmsProgressGuard()
    startThumperSmsLivePolling()
  }
}

document.addEventListener("turbo:load", bootThumperLiveRuntime)
document.addEventListener("DOMContentLoaded", bootThumperLiveRuntime)
window.addEventListener("pageshow", bootThumperLiveRuntime)
window.addEventListener("focus", () => {
  if (THUMPER_SMS_LEGACY_LIVE_ENABLED) window.setTimeout(pollOpenThumperSmsStations, 60)
})
window.setTimeout(bootThumperLiveRuntime, 0)
