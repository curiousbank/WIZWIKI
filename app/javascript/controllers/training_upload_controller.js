import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["fileInput", "folderInput", "manifest", "panel", "summary", "message", "meter", "submit"]

  static values = {
    maxBytes: { type: Number, default: 52428800 },
    maxFiles: { type: Number, default: 200 },
  }

  connect() {
    this.update()
  }

  update() {
    const files = this.selectedFiles()
    this.updateManifest(files)
    const totalBytes = files.reduce((sum, file) => sum + file.size, 0)
    const folderCount = this.folderCount(files)
    const unsupportedCount = this.unsupportedCount(files)
    const storableCount = Math.max(files.length - unsupportedCount, 0)
    const overFileLimit = files.length > this.maxFilesValue
    const overByteLimit = totalBytes > this.maxBytesValue
    const invalid = overFileLimit || overByteLimit

    this.element.dataset.trainingUploadState = files.length > 0 ? (invalid ? "warning" : "ready") : "idle"
    this.setPanelClass(invalid, false)
    this.setMeter(totalBytes)

    if (files.length === 0) {
      this.summaryTarget.textContent = "No files selected."
      this.messageTarget.textContent = "Choose files, choose a folder, or paste text. When you press store, this panel will stay active until SUN finishes saving the material."
      this.enableSubmit()
      return
    }

    const folderText = folderCount > 0 ? ` // ${folderCount} folder${folderCount === 1 ? "" : "s"}` : ""
    const storableText = files.length > 0 ? ` // ${storableCount} storable` : ""
    const unsupportedText = unsupportedCount > 0 ? ` // ${unsupportedCount} unsupported` : ""
    this.summaryTarget.textContent = `${files.length} file${files.length === 1 ? "" : "s"} // ${this.formatBytes(totalBytes)}${folderText}${storableText}${unsupportedText} // cap ${this.maxFilesValue}`

    if (invalid) {
      const warnings = []
      if (overFileLimit) warnings.push(`limit is ${this.maxFilesValue} files`)
      if (overByteLimit) warnings.push(`limit is ${this.formatBytes(this.maxBytesValue)}`)
      this.messageTarget.textContent = `This batch is too large: ${warnings.join(" and ")}. Split the folder into smaller batches before storing.`
      this.disableSubmit()
    } else {
      const skipNote = unsupportedCount > 0 ? ` ${unsupportedCount} unsupported file${unsupportedCount === 1 ? "" : "s"} will be skipped; supported PDFs and text-like files will be stored.` : ""
      this.messageTarget.textContent = `Ready to store within the ${this.maxFilesValue}-file cap. Thumper will save TXT, MD, CSV, JSON, and readable PDF text now; an admin can queue vector memory after review.${skipNote}`
      this.enableSubmit()
    }
  }

  submit(event) {
    if (this.element.dataset.trainingUploadState === "warning") {
      event.preventDefault()
      this.messageTarget.textContent = "Upload blocked before submit because this batch is larger than the WIZWIKI training limit."
      return
    }

    this.setPanelClass(false, true)
    this.element.setAttribute("aria-busy", "true")
    this.summaryTarget.textContent = this.selectedFiles().length > 0 ? "Storing selected training files..." : "Storing pasted training text..."
    this.messageTarget.textContent = "Upload in progress. Keep this tab open; the page will return with a stored-document count when SUN finishes."

    if (this.hasSubmitTarget) {
      this.submitTarget.value = "STORING TRAINING..."
      window.setTimeout(() => {
        this.submitTarget.disabled = true
      }, 0)
    }
  }

  selectedFiles() {
    return [this.fileInputTarget, this.folderInputTarget].flatMap((input) => {
      return Array.from(input.files || [])
    })
  }

  updateManifest(files = this.selectedFiles()) {
    if (!this.hasManifestTarget) return

    this.manifestTarget.value = JSON.stringify(files.map((file, index) => {
      return {
        index,
        name: file.name || "",
        size: file.size || 0,
        type: file.type || "",
        relative_path: file.webkitRelativePath || file.name || "",
      }
    }))
  }

  folderCount(files) {
    const roots = files
      .map((file) => file.webkitRelativePath || "")
      .filter((path) => path.includes("/"))
      .map((path) => path.split("/")[0])

    return new Set(roots).size
  }

  unsupportedCount(files) {
    return files.filter((file) => !this.supportedFile(file)).length
  }

  supportedFile(file) {
    const name = (file.name || "").toLowerCase()
    const type = (file.type || "").toLowerCase()
    return (
      name.endsWith(".txt") ||
      name.endsWith(".md") ||
      name.endsWith(".markdown") ||
      name.endsWith(".csv") ||
      name.endsWith(".json") ||
      name.endsWith(".pdf") ||
      type === "text/plain" ||
      type === "text/markdown" ||
      type === "text/csv" ||
      type === "application/csv" ||
      type === "application/json" ||
      type === "application/pdf"
    )
  }

  setPanelClass(warning, uploading) {
    if (!this.hasPanelTarget) return

    this.panelTarget.classList.toggle("training-upload-feedback--warning", warning)
    this.panelTarget.classList.toggle("training-upload-feedback--uploading", uploading)
    this.panelTarget.classList.toggle("training-upload-feedback--ready", !warning && !uploading && this.selectedFiles().length > 0)
  }

  setMeter(totalBytes) {
    if (!this.hasMeterTarget) return

    const percent = this.maxBytesValue > 0 ? Math.min(100, Math.round((totalBytes / this.maxBytesValue) * 100)) : 0
    this.meterTarget.style.width = `${percent}%`
  }

  enableSubmit() {
    if (this.hasSubmitTarget) this.submitTarget.disabled = false
  }

  disableSubmit() {
    if (this.hasSubmitTarget) this.submitTarget.disabled = true
  }

  formatBytes(bytes) {
    if (!bytes) return "0 B"

    const units = ["B", "KB", "MB", "GB"]
    let value = bytes
    let index = 0

    while (value >= 1024 && index < units.length - 1) {
      value /= 1024
      index += 1
    }

    return `${value >= 10 || index === 0 ? Math.round(value) : value.toFixed(1)} ${units[index]}`
  }
}
