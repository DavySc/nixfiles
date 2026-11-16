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

// VS Code's right-click menu on the infoview (vscode-lean4's package.json,
// "webview/context"): the infoview marks what is under the mouse with
// data-vscode-context, the nearest mark winning; an entry shows when its key
// is there, and a click hands the entry and the key's id back to it.
const item = (entry, title, key = entry + 'Id') => [key, entry, title]
const groups = [
    [item('goToDefinition', 'Go to Definition', 'interactiveCodeTagId'),
        item('goToPinnedLocation', 'Go to Pinned Location'),
        item('goToMessageLocation', 'Go to Source Location of Message'),
        item('hideTraceSearch', 'Hide Search'), item('showTraceSearch', 'Show Search'),
        item('select', 'Select', 'selectableLocationId'),
        item('unselect', 'Unselect', 'unselectableLocationId'),
        item('unselectAll', 'Unselect All', 'selectedLocationsId')],
    [item('pin', 'Pin State to Top'), item('unpin', 'Unpin State'),
        item('pause', 'Pause State'), item('unpause', 'Unpause State'),
        item('refresh', 'Refresh Paused State'),
        item('pauseAllMessages', "Pause 'All Messages'"), item('unpauseAllMessages', "Unpause 'All Messages'"),
        item('copyState', 'Copy State'), item('copyMessage', 'Copy Message')],
    // VS Code's "Settings…" submenu, here as the menu's last part
    [item('displayTargetBeforeAssumptions', 'Display Target Before Assumptions'),
        item('displayAssumptionsBeforeTarget', 'Display Assumptions Before Target'),
        item('hideTypeAssumptions', 'Hide Type Assumptions'), item('showTypeAssumptions', 'Show Type Assumptions'),
        item('hideInstanceAssumptions', 'Hide Instance Assumptions'),
        item('showInstanceAssumptions', 'Show Instance Assumptions'),
        item('hideInaccessibleAssumptions', 'Hide Inaccessible Assumptions'),
        item('showInaccessibleAssumptions', 'Show Inaccessible Assumptions'),
        item('hideLetValues', 'Hide Let-Values'), item('showLetValues', 'Show Let-Values'),
        item('hideGoalNames', 'Hide Goal Names'), item('showGoalNames', 'Show Goal Names'),
        item('emphasizeFirstGoal', 'Emphasize First Goal'), item('deemphasizeFirstGoal', 'De-Emphasize First Goal'),
        item('saveSettings', 'Save Current Settings to Default Settings')],
]

let menu = null
const closeMenu = () => { menu?.remove(); menu = null }
addEventListener('contextmenu', e => {
    const ctx = {}
    for (let el = e.target; el instanceof Element; el = el.parentElement)
        for (const [k, v] of Object.entries(JSON.parse(el.getAttribute('data-vscode-context') || '{}')))
            if (!(k in ctx)) ctx[k] = v
    const selected = String(getSelection())
    const shown = [selected ? [['Copy', () => editorApi.copyToClipboard(selected)]] : [],
        ...groups.map(g => g.filter(([key]) => ctx[key]).map(([key, entry, title]) =>
            [title, () => window.kittyInfoview.clickedContextMenu({ entry, id: ctx[key] })]))]
        .filter(g => g.length)
    if (!shown.length || !window.kittyInfoview) return
    e.preventDefault()
    closeMenu()
    menu = document.createElement('div')
    menu.className = 'kitty-menu'
    shown.forEach((g, n) => {
        if (n) menu.append(document.createElement('hr'))
        for (const [title, act] of g) {
            const b = document.createElement('button')
            b.textContent = title
            b.onclick = () => { closeMenu(); act() }
            menu.append(b)
        }
    })
    document.body.append(menu)
    menu.style.left = Math.max(0, Math.min(e.clientX, innerWidth - menu.offsetWidth)) + 'px'
    menu.style.top = Math.max(0, Math.min(e.clientY, innerHeight - menu.offsetHeight)) + 'px'
})
addEventListener('mousedown', e => { if (menu && !menu.contains(e.target)) closeMenu() })
addEventListener('keydown', e => { if (e.key === 'Escape') closeMenu() })
addEventListener('blur', closeMenu)
addEventListener('scroll', closeMenu, true)
