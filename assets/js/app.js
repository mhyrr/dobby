// If you want to use Phoenix channels, run `mix help phx.gen.channel`
// to get started and then uncomment the line below.
// import "./user_socket.js"

// You can include dependencies in two ways.
//
// The simplest option is to put them in assets/vendor and
// import them using relative paths:
//
//     import "../vendor/some-package.js"
//
// Alternatively, you can `npm install some-package --prefix assets` and import
// them using a path starting with the package name:
//
//     import "some-package"
//
// If you have dependencies that try to import CSS, esbuild will generate a separate `app.css` file.
// To load it, simply add a second `<link>` to your `root.html.heex` file.

// Include phoenix_html to handle method=PUT/DELETE in forms and buttons.
import "phoenix_html"
// Establish Phoenix Socket and LiveView configuration.
import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"
import {hooks as colocatedHooks} from "phoenix-colocated/dobby"
import topbar from "../vendor/topbar"

const csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")
const liveSocket = new LiveSocket("/live", Socket, {
  longPollFallbackMs: 2500,
  params: {_csrf_token: csrfToken},
  hooks: {...colocatedHooks},
})

// Show progress bar on live navigation and form submits
topbar.config({barColors: {0: "#29d"}, shadowColor: "rgba(0, 0, 0, .3)"})
window.addEventListener("phx:page-loading-start", _info => topbar.show(300))
window.addEventListener("phx:page-loading-stop", _info => topbar.hide())

// ── the board's one moving part ─────────────────────────────────────────────
// A split-flap board's whole magic is the mechanism, and until now the fold had
// never moved: a state word silently became a different state word. When one
// changes the card now turns over and lands on the new one.
//
// A MutationObserver rather than a phx-hook, because flaps are rendered in
// loops, inside streams, on three pages, and not one of them has an id to hang
// a hook on. Watching characterData alone is deliberate: the thing worth
// animating is a word *changing*, not a flap arriving. A new system line should
// appear, not flap.
const reduceMotion = window.matchMedia("(prefers-reduced-motion: reduce)")

new MutationObserver(records => {
  if (reduceMotion.matches) return

  const turned = new Set()

  for (const record of records) {
    const node = record.target.nodeType === Node.TEXT_NODE ? record.target.parentElement : record.target
    const flap = node && node.closest && node.closest(".flap")

    // One turn per card per batch: a word and its state colour change together,
    // and two overlapping animations on one card read as a stutter.
    if (flap && !turned.has(flap)) {
      turned.add(flap)
      // A card falls, overshoots its stop, and settles — which is what makes it
      // read as a physical thing landing rather than a value being replaced.
      // The easing is per-keyframe on purpose: one curve across the whole turn
      // dumped most of the rotation into the first 40ms and read as a snap.
      flap.animate(
        [{transform: "perspective(340px) rotateX(-88deg)", easing: "cubic-bezier(.5,0,.7,.6)"},
         {transform: "perspective(340px) rotateX(9deg)", offset: 0.68, easing: "ease-out"},
         {transform: "perspective(340px) rotateX(0deg)"}],
        {duration: 300}
      )
    }
  }
}).observe(document.body, {subtree: true, characterData: true})

// connect if there are any LiveViews on the page
liveSocket.connect()

// expose liveSocket on window for web console debug logs and latency simulation:
// >> liveSocket.enableDebug()
// >> liveSocket.enableLatencySim(1000)  // enabled for duration of browser session
// >> liveSocket.disableLatencySim()
window.liveSocket = liveSocket

// The lines below enable quality of life phoenix_live_reload
// development features:
//
//     1. stream server logs to the browser console
//     2. click on elements to jump to their definitions in your code editor
//
if (process.env.NODE_ENV === "development") {
  window.addEventListener("phx:live_reload:attached", ({detail: reloader}) => {
    // Enable server log streaming to client.
    // Disable with reloader.disableServerLogs()
    reloader.enableServerLogs()

    // Open configured PLUG_EDITOR at file:line of the clicked element's HEEx component
    //
    //   * click with "c" key pressed to open at caller location
    //   * click with "d" key pressed to open at function component definition location
    let keyDown
    window.addEventListener("keydown", e => keyDown = e.key)
    window.addEventListener("keyup", _e => keyDown = null)
    window.addEventListener("click", e => {
      if(keyDown === "c"){
        e.preventDefault()
        e.stopImmediatePropagation()
        reloader.openEditorAtCaller(e.target)
      } else if(keyDown === "d"){
        e.preventDefault()
        e.stopImmediatePropagation()
        reloader.openEditorAtDef(e.target)
      }
    }, true)

    window.liveReloader = reloader
  })
}

