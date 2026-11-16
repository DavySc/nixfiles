// The editor side of VS Code's infoview, for kittymax: every EditorApi call
// goes to Emacs as a POST, every InfoviewApi call and every answer comes
// back on one event stream.  See kitty-lean-webview.el.
import { loadRenderInfoview } from './dist/loader.production.min.js'

const base = new URL('.', location.href)
const page = (crypto.randomUUID ? crypto.randomUUID() : String(Math.random()).slice(2))
const pending = new Map()
let next = 0

// The infoview listens for the editor's events from React effects: one
// fired between its first render and those effects is lost (useEventResult
// reads the last value only while rendering).  Its first call to the editor
// comes from one of those effects (a subscription, at mount), so the event
// stream opens just after it.  sendClientRequest's cancellation
// (options.abortSignal) does not cross to Lean: its answer comes, unused.
let mounted
const mountedP = new Promise(resolve => { mounted = resolve })

function call(m, ...a) {
    setTimeout(() => mounted(), 0)
    const id = next++
    return new Promise((resolve, reject) => {
        pending.set(id, { resolve, reject })
        fetch(new URL('call?page=' + page, base), { method: 'POST', body: JSON.stringify({ id, m, a }) })
            .catch(e => { pending.delete(id); reject(e) })
    })
}

const editorApi = {}
for (const m of ['saveConfig', 'sendClientRequest', 'sendClientNotification',
    'subscribeServerNotifications', 'unsubscribeServerNotifications',
    'subscribeClientNotifications', 'unsubscribeClientNotifications',
    'copyToClipboard', 'insertText', 'applyEdit', 'showDocument', 'restartFile',
    'createRpcSession', 'closeRpcSession'])
    editorApi[m] = (...a) => call(m, ...a)

function answer(msg) {
    const p = pending.get(msg.id)
    if (!p) return
    pending.delete(msg.id)
    if (msg.k === 'raw') {
        if (msg.v.error) p.reject(msg.v.error)
        else p.resolve(msg.v.result)
    } else if (msg.k === 'err') p.reject(msg.v)
    else p.resolve(msg.v)
}

const imports = {}
for (const [name, file] of [['@leanprover/infoview', 'index.production.min.js'],
    ['react', 'react.production.min.js'], ['react/jsx-runtime', 'react-jsx-runtime.production.min.js'],
    ['react-dom', 'react-dom.production.min.js']])
    imports[name] = new URL('dist/' + file, base).href

loadRenderInfoview(imports, [editorApi, document.getElementById('react_root')], async api => {
    await mountedP
    window.kittyInfoview = api
    const events = new EventSource(new URL('events?page=' + page, base))
    events.onmessage = e => {
        const msg = JSON.parse(e.data)
        // Emacs forgot this page (its stream was down too long): start afresh
        if (msg.reload) location.reload()
        else if ('id' in msg) answer(msg)
        else if (msg.raw) void api[msg.m](msg.n, msg.raw.params)
        else void api[msg.m](...msg.a)
    }
})
