import "phoenix_html"
import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"

const csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")

const RichTextEditor = {
  mounted() {
    this.textarea = this.el.querySelector("textarea")
    this.handleClick = event => {
      const button = event.target.closest("[data-rich-action]")
      if (!button || !this.el.contains(button)) return

      event.preventDefault()

      const action = button.dataset.richAction
      if (action === "insert") this.insert(button.dataset.richInsert)
      if (action === "bold") this.wrap("**", "**", "bold text")
      if (action === "italic") this.wrap("*", "*", "italic text")
      if (action === "underline") this.wrap("++", "++", "underlined text")
      if (action === "strike") this.wrap("~~", "~~", "struck text")
      if (action === "bullet-list") this.prefixLines(line => `- ${line}`)
      if (action === "numbered-list") this.prefixLines((line, index) => `${index + 1}. ${line}`)
      if (action === "quote") this.prefixLines(line => `> ${line}`)
      if (action === "link") this.addLink()
      if (action === "gif") this.attachGif()
      if (action === "remove-gif") this.setGif("")
    }

    this.el.addEventListener("click", this.handleClick)
  },

  destroyed() {
    this.el.removeEventListener("click", this.handleClick)
  },

  updated() {
    this.textarea = this.el.querySelector("textarea")
  },

  selectedText(fallback) {
    return this.textarea.value.slice(this.textarea.selectionStart, this.textarea.selectionEnd) || fallback
  },

  replaceSelection(value, selectFrom = value.length, selectTo = value.length) {
    const start = this.textarea.selectionStart
    const end = this.textarea.selectionEnd
    this.textarea.setRangeText(value, start, end)
    this.textarea.focus()
    this.textarea.setSelectionRange(start + selectFrom, start + selectTo)
    this.textarea.dispatchEvent(new Event("input", {bubbles: true}))
  },

  insert(value) {
    this.replaceSelection(value)
  },

  wrap(before, after, fallback) {
    const selected = this.selectedText(fallback)
    this.replaceSelection(
      `${before}${selected}${after}`,
      before.length,
      before.length + selected.length,
    )
  },

  prefixLines(format) {
    const lines = this.selectedText("list item").split(/\r?\n/)
    this.replaceSelection(lines.map(format).join("\n"))
  },

  addLink() {
    const url = window.prompt("Paste an HTTPS link")
    if (!url) return
    if (!/^https:\/\/\S+$/i.test(url)) return window.alert("Use a complete HTTPS link.")

    const label = this.selectedText("link text")
    this.replaceSelection(`[${label}](${url})`)
  },

  attachGif() {
    const current = this.el.querySelector("[data-gif-url]")?.value || ""
    const url = window.prompt("Paste a direct HTTPS .gif URL", current)
    if (url === null) return
    if (url && !/^https:\/\/\S+\.gif(?:[?#]\S*)?$/i.test(url)) {
      return window.alert("Use a direct HTTPS URL ending in .gif.")
    }
    this.setGif(url)
  },

  setGif(url) {
    const input = this.el.querySelector("[data-gif-url]")
    if (!input) return

    input.value = url
    input.dispatchEvent(new Event("input", {bubbles: true}))
    this.el.querySelector("[data-gif-status]").textContent = url ? "GIF attached" : "No GIF attached"
    this.el.querySelector("[data-remove-gif]").hidden = !url
  },
}

const liveSocket = new LiveSocket("/live", Socket, {
  params: {_csrf_token: csrfToken},
  hooks: {RichTextEditor},
})

liveSocket.connect()
window.liveSocket = liveSocket

if (process.env.NODE_ENV === "development") {
  window.addEventListener("phx:live_reload:attached", ({detail: reloader}) => {
    reloader.enableServerLogs()
    window.liveReloader = reloader
  })
}
