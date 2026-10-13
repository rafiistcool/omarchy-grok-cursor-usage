import QtQuick
import QtQuick.Controls
import QtQuick.Effects
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons
import qs.Ui

Panel {
  id: root
  moduleName: "rafi.agents"
  ipcTarget: "rafi.agents"
  manageIpc: false

  readonly property color foreground: bar ? bar.foreground : Commons.Color.foreground
  readonly property color urgent: bar ? bar.urgent : Commons.Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property color surface: Commons.Color.popups.background
  readonly property color track: Style.selectedFillFor(foreground, Commons.Color.accent)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  // Grok/Codex marks live in the omarchy icon font (U+E904/E905), not in the
  // user's monospace/text face. Bind icons to "omarchy" like omarchy.menu does.
  readonly property string iconFontFamily: "omarchy"
  // The glyph every Omarchy agents surface shares: the hero's mark, and the
  // stand-in for a provider that ships no mark of its own.
  readonly property string agentsGlyph: "󱚣"

  readonly property var providers: usage.enabledProviders
  // The selection follows the provider, not the slot it happens to sit in: a
  // provider whose first scan lands while the panel is open would otherwise
  // shift the list underneath you and swap out what you were reading.
  property string selectedProviderId: ""
  readonly property int providerIndex: {
    var fallback = 0
    for (var i = 0; i < providers.length; i++) {
      if (providers[i].providerId === selectedProviderId) return i
      if (providers[i].providerId === "grok") fallback = i
    }
    return fallback
  }
  readonly property var provider: providers.length > 0 ? providers[providerIndex] : null

  property bool cursorActive: false

  // Countdowns and "updated" read this instead of Date.now() so the
  // panel keeps telling the truth while it sits open.
  property double nowMs: Date.now()

  // Every account of every provider that has more than one, in page order.
  // The keyboard picks one by its position; picking only looks, and Enter on
  // a picked account is what moves new sessions to it.
  readonly property var accountEntries: {
    var out = []
    for (var i = 0; i < providers.length; i++) {
      var list = providerAccounts(providers[i])
      if (list.length < 2) continue
      for (var j = 0; j < list.length; j++) out.push({ provider: providers[i], account: list[j] })
    }
    return out
  }
  readonly property var pickedEntry: keyTarget && ["account", "autoswitch", "signin"].indexOf(keyTarget.kind) >= 0
    ? accountEntries[keyTarget.index] || null
    : null

  // The keyboard walks everything on the page that does something, in
  // reading order, one row at a time: the hero's buttons, then each agent's
  // header, its Sign-in required link or switchable accounts, the headers
  // that fold its token tables, and the starter
  // tiles, or the agents to add while picking one. Up and down change rows,
  // left and right move along one. Hovering moves the same cursor, so only
  // one thing is lit.
  readonly property var keyRows: {
    var rows = []
    var hero = []
    if (addButtonShown) hero.push({ kind: "add", index: 0 })
    if (addStage === "") hero.push({ kind: "launch", index: 0 })
    if (hero.length > 0) rows.push(hero)
    if (picking) {
      var choices = []
      for (var k = 0; k < addProviders.length; k++) choices.push({ kind: "choice", index: k })
      rows.push(choices)
    } else if (addStage === "") {
      // Accounts count in the same order as accountEntries. Only what can be
      // done is a stop: one that isn't active offers Autoswitch beside Use, a
      // lapsed sign-in comes first, and the active account with nothing to
      // fix is skipped.
      var entry = 0
      for (var p = 0; p < providers.length; p++) {
        // Every agent's header is a stop, so Ctrl+Up/Down can move it.
        rows.push([{ kind: "provider", index: p }])
        var accounts = providerAccounts(providers[p])
        if (accounts.length < 2) {
          if (signInOffered(providers[p])) rows.push([{ kind: "providerSignin", index: p }])
        } else {
          for (var a = 0; a < accounts.length; a++, entry++) {
            var row = []
            if (needsSignIn(accounts[a])) row.push({ kind: "signin", index: entry })
            if (!accounts[a].active) {
              row.push({ kind: "autoswitch", index: entry })
              row.push({ kind: "account", index: entry })
            }
            if (row.length > 0) rows.push(row)
          }
        }
        if (hasDayTokens(providers[p])) rows.push([{ kind: "days", index: p }])
        if (hasModelTokens(providers[p])) rows.push([{ kind: "models", index: p }])
      }
      if (!blankSlate) {
        var tiles = []
        for (var j = 0; j < starterPrompts.length; j++) tiles.push({ kind: "starter", index: j })
        rows.push(tiles)
      }
    }
    return rows
  }
  property int keyRow: 0
  property int keyColumn: 0
  readonly property var keyTarget: {
    if (!cursorActive || keyRow < 0 || keyRow >= keyRows.length) return null
    var row = keyRows[keyRow]
    return row[Math.min(keyColumn, row.length - 1)]
  }

  function hasKey(kind, index) {
    return !!keyTarget && keyTarget.kind === kind && keyTarget.index === (index || 0)
  }

  function pointAt(kind, index) {
    for (var r = 0; r < keyRows.length; r++) {
      for (var c = 0; c < keyRows[r].length; c++) {
        if (keyRows[r][c].kind === kind && keyRows[r][c].index === (index || 0)) {
          keyRow = r
          keyColumn = c
          cursorActive = true
          return
        }
      }
    }
  }

  // The first arrow only shows where the cursor is, as in the other panels.
  function moveKey(dx, dy) {
    if (keyRows.length === 0) return
    if (!cursorActive) {
      keyRow = clamp(keyRow, 0, keyRows.length - 1)
      keyColumn = 0
      cursorActive = true
      return
    }
    if (dy !== 0) {
      if (scrollWithinBlock(dy)) return
      keyRow = clamp(keyRow + dy, 0, keyRows.length - 1)
      // Arriving on an account lands on Use; left reaches Autoswitch.
      var row = keyRows[keyRow]
      var use = -1
      for (var c = 0; c < row.length; c++) if (row[c].kind === "account") use = c
      keyColumn = use >= 0 ? use : Math.min(keyColumn, row.length - 1)
    } else if (dx !== 0) {
      keyColumn = clamp(Math.min(keyColumn, keyRows[keyRow].length - 1) + dx, 0, keyRows[keyRow].length - 1)
    }
  }

  // The agent a row of the cursor's walk belongs to, by its position on the
  // page, or -1 for the hero's buttons and the starter tiles.
  function providerIndexOfRow(r) {
    if (r < 0 || r >= keyRows.length || keyRows[r].length === 0) return -1
    var target = keyRows[r][0]
    if (["provider", "providerSignin", "days", "models"].indexOf(target.kind) >= 0) return target.index
    if (["account", "autoswitch", "signin"].indexOf(target.kind) < 0) return -1
    var entry = accountEntries[target.index]
    return entry ? providers.indexOf(entry.provider) : -1
  }

  // The agent the cursor is in.
  function providerIndexOfKey() {
    return keyTarget ? providerIndexOfRow(keyRow) : -1
  }

  // Ctrl+Up/Down carries the agent the cursor is in up or down the page, and
  // the cursor along with it.
  function reorderProvider(dy) {
    var from = providerIndexOfKey()
    if (from < 0) return
    var to = clamp(from + dy, 0, providers.length - 1)
    if (to === from) return
    usage.moveProvider(providers[from].providerId, to)
    Qt.callLater(function() { pointAt("provider", to) })
  }

  // Dragging an agent by its mark lights the header it would land on, and
  // moves it there on release: the sections are rebuilt when the order
  // changes, which would drop a drag still in progress.
  property string dragProviderId: ""
  property int dragTarget: -1
  // An account name being edited keeps Ctrl+Up/Down: moving its agent would
  // rebuild the section and drop the unfinished name.
  property bool renaming: false

  function dragProviderOver(y) {
    for (var i = 0; i < providerSections.count; i++) {
      var item = providerSections.itemAt(i)
      if (item && y >= item.y && y < item.y + item.height) {
        dragTarget = i
        return
      }
    }
  }

  function dropProvider() {
    var id = dragProviderId
    var to = dragTarget
    dragProviderId = ""
    dragTarget = -1
    if (id === "" || to < 0) return
    usage.moveProvider(id, to)
    Qt.callLater(function() { pointAt("provider", to) })
  }

  // Keeps whatever the cursor lands on inside the scrolled view.
  function revealItem(item) {
    if (!item || !panelFlick.interactive) return
    var top = item.mapToItem(column, 0, 0).y
    var margin = Style.space(12)
    if (top - margin < panelFlick.contentY)
      panelFlick.contentY = Math.max(0, top - margin)
    else if (top + item.height + margin > panelFlick.contentY + panelFlick.height)
      panelFlick.contentY = Math.min(panelFlick.contentHeight - panelFlick.height, top + item.height + margin - panelFlick.height)
  }

  // An agent's section here runs taller than a line of limits: it can carry
  // a chart and two tables. Landing on its header shows the whole section
  // when it fits, and its top when it doesn't.
  function revealBlock(block) {
    if (!block || !panelFlick.interactive) return
    var top = block.mapToItem(column, 0, 0).y
    var margin = Style.space(12)
    var maxY = Math.max(0, panelFlick.contentHeight - panelFlick.height)
    if (top - margin < panelFlick.contentY || block.height + margin * 2 > panelFlick.height)
      panelFlick.contentY = clamp(top - margin, 0, maxY)
    else if (top + block.height + margin > panelFlick.contentY + panelFlick.height)
      panelFlick.contentY = clamp(top + block.height + margin - panelFlick.height, 0, maxY)
  }

  // A section that doesn't fit the panel is scrolled through before the
  // cursor leaves it, so the arrows still reach every row of it.
  function scrollWithinBlock(dy) {
    if (!panelFlick.interactive) return false
    var index = providerIndexOfRow(keyRow)
    if (index < 0 || providerIndexOfRow(keyRow + dy) === index) return false
    var block = providerSections.itemAt(index)
    if (!block) return false
    var top = block.mapToItem(column, 0, 0).y
    var bottom = top + block.height
    var view = panelFlick.height
    var margin = Style.space(12)
    var step = Style.space(112)
    var maxY = Math.max(0, panelFlick.contentHeight - view)
    if (dy > 0 && panelFlick.contentY < maxY - 1 && bottom + margin > panelFlick.contentY + view + 1) {
      panelFlick.contentY = Math.min(maxY, panelFlick.contentY + step, bottom + margin - view)
      return true
    }
    if (dy < 0 && panelFlick.contentY > 1 && top - margin < panelFlick.contentY - 1) {
      panelFlick.contentY = Math.max(0, panelFlick.contentY - step, top - margin)
      return true
    }
    return false
  }

  readonly property var limits: limitWindows(provider)
  readonly property var models: modelRows(provider)
  readonly property var headline: bindingWindow(provider)
  readonly property var balance: provider ? (provider.balance || null) : null
  readonly property bool balanceAlarming: balanceLow(balance)
  readonly property bool alarming: (!!headline && headline.percent >= 0.9) || balanceAlarming
  // Menubar leftover is Grok's weekly pool only. Cursor Ultra lives in the
  // popup so a middle-click does not swap the tray meter.
  readonly property var grokProvider: {
    var list = providers || []
    for (var i = 0; i < list.length; i++)
      if (String(list[i].providerId) === "grok") return list[i]
    return null
  }
  readonly property real remainingRatio: {
    var source = grokProvider || provider
    var window = null
    var list = source ? limitWindows(source) : []
    for (var i = 0; i < list.length; i++) {
      if (String(list[i].title || "") === "Weekly") { window = list[i]; break }
    }
    if (!window && list.length > 0) window = list[0]
    if (!window) return -1
    var used = Number(window.percent)
    if (!(used >= 0)) return -1
    return clamp(1 - used, 0, 1)
  }
  readonly property int remainingPct: remainingRatio >= 0 ? Math.round(remainingRatio * 100) : -1
  readonly property var weeklyWindow: {
    var list = grokProvider ? limitWindows(grokProvider) : (limits || [])
    for (var i = 0; i < list.length; i++)
      if (String(list[i].title || "") === "Weekly") return list[i]
    return list.length > 0 ? list[0] : null
  }
  // The page's order lives in the backend, where dragging an agent saves it.
  // Until someone does, Grok, Grok Bot, and Cursor lead.
  readonly property var stackedProviders: providers
  readonly property int firstChartProviderIndex: {
    var list = stackedProviders || []
    for (var i = 0; i < list.length; i++) {
      var id = String(list[i].providerId || "")
      if (id !== "grok" && id !== "grokbot" && id !== "cursor" && id !== "codex" && id !== "antigravity") continue
      var series = remainingSeriesFor(list[i])
      if (series && series.length > 0) return i
    }
    return -1
  }
  readonly property string remainingStyle: {
    var value = String(setting("remainingStyle", "logo-on-bar")).trim().toLowerCase()
    if (value === "logo-bar" || value === "bar-percent" || value === "percent") return value
    return "logo-on-bar"
  }
  readonly property bool remainingShowPercent: settingOn("remainingShowPercent", remainingStyle === "bar-percent" || remainingStyle === "percent")
  readonly property int remainingLogoSize: settingNumber("remainingLogoSize", 13, 8, 22)
  readonly property int remainingBarWidth: settingNumber("remainingBarWidth", remainingStyle === "logo-bar" ? 3 : remainingLogoSize, 2, 80)
  readonly property int remainingBarHeight: settingNumber("remainingBarHeight", remainingStyle === "logo-bar" ? remainingLogoSize : 4, 2, 48)
  readonly property int remainingBarGap: settingNumber("remainingBarGap", 4, 1, 12)
  readonly property int remainingFontSize: settingNumber("remainingFontSize", 10, 7, 16)
  // "days" is a 2-day span (now-1.8d .. now+0.2d, snapped to quarter-hours).
  // Start special: quota start is inside the lookback → left edge is the
  // quarter-hour at or before the first sample. End special: reset is within
  // 2 days → right edge is the reset. One special keeps the 2-day width;
  // both (impossible on a 7-day cycle) allow a shorter span. "cycle" is
  // first sample .. resetsAt. Charts skip 5h pools; only 7-day+ windows.
  readonly property string remainingAxis: {
    var value = String(setting("remainingAxis", "days")).trim().toLowerCase()
    if (value === "cycle" || value === "window" || value === "period" || value === "quota") return "cycle"
    return "days"
  }
  // Charts skip 5h/session pools. Slack covers 7-day windows that run a hair short.
  readonly property real remainingMinWindowMs: (7 * 24 * 3600 - 2 * 3600) * 1000

  // Same box as Bar.qml ModuleSlot.openPanelIndicator: 55% of the icon
  // slot, 2px thick, 2px in from the desktop-facing edge, centered. The
  // leftover meter hides when the panel opens, so these have to share one
  // rect or the mark jumps.
  readonly property bool vertical: bar ? bar.vertical : false
  readonly property string barPosition: bar ? String(bar.position) : "top"
  readonly property int remainingMeterThickness: Style.space(2)
  readonly property int remainingMeterInset: Style.space(2)
  readonly property real remainingMeterLength: {
    var slot = vertical ? implicitHeight : implicitWidth
    if (!(slot > 0)) slot = Style.bar.iconSlot
    return Math.max(Style.space(10), Math.round(slot * 0.55))
  }
  readonly property real openPanelIndicatorWidth: vertical ? 0 : remainingMeterLength
  readonly property real openPanelIndicatorHeight: vertical ? remainingMeterLength : 0

  readonly property var grokRemaining: usage.remainingHistory.grok || null
  readonly property var grokbotRemaining: usage.remainingHistory.grokbot || null
  readonly property var cursorRemaining: usage.remainingHistory.cursor || null
  readonly property var codexRemaining: usage.remainingHistory.codex || null
  readonly property var antigravityRemaining: usage.remainingHistory.antigravity || null
  readonly property string agentsHistoryDir: (Quickshell.env("XDG_STATE_HOME") || ((Quickshell.env("HOME") || "") + "/.local/state")) + "/omarchy/agents/history"

  function clamp(v, lo, hi) { return Math.max(lo, Math.min(hi, v)) }
  // Shell animations run for Style.duration(ms), which is 0 while motion is
  // turned off. A shell from before that existed simply animates.
  function motion(ms) { return typeof Style.duration === "function" ? Style.duration(ms) : ms }
  function alpha(c, a) { return Qt.rgba(c.r, c.g, c.b, a) }

  function settingNumber(name, fallback, min, max) {
    var n = Number(setting(name, fallback))
    if (!isFinite(n)) n = fallback
    return clamp(Math.round(n), min, max)
  }

  function persistSettings(values) {
    var id = root.moduleName || "rafi.agents"
    var entry = { id: id }
    var current = root.settings || {}
    for (var existing in current)
      if (existing !== "id") entry[existing] = current[existing]
    for (var key in values) entry[key] = values[key]
    root.settings = entry
    if (root.bar && root.bar.shell && typeof root.bar.shell.updateEntryInline === "function")
      root.bar.shell.updateEntryInline(id, entry)
  }

  function setRemainingAxis(mode) {
    var next = String(mode || "") === "cycle" ? "cycle" : "days"
    if (next === root.remainingAxis) return
    persistSettings({ remainingAxis: next })
  }

  // The token tables fold away behind their headers and start closed: the
  // page is for what's left, and the history is a click away. The ones left
  // open are kept with the widget's other settings, a "<provider>.<section>"
  // entry each.
  readonly property var openTokenSections: {
    var saved = setting("openTokenSections", [])
    var list = []
    if (saved && typeof saved !== "string" && saved.length !== undefined)
      for (var i = 0; i < saved.length; i++) list.push(String(saved[i]))
    return list
  }

  function tokenSectionOpen(p, section) {
    return !!p && openTokenSections.indexOf(p.providerId + "." + section) >= 0
  }

  function toggleTokenSection(p, section) {
    if (!p) return
    var key = p.providerId + "." + section
    var next = openTokenSections.filter(function(entry) { return entry !== key })
    if (next.length === openTokenSections.length) next.push(key)
    persistSettings({ openTokenSections: next })
  }

  function hasDayTokens(p) {
    return !!p && !!p.recentDays && p.recentDays.length > 0
  }

  function hasModelTokens(p) {
    return modelRows(p).length > 0
  }

  // What a closed table still says in its header.
  function dayTokensSummary(p) {
    return hasDayTokens(p) ? usage.formatTokenCount(Number(p.todayTotalTokens || 0)) + " today" : ""
  }

  function modelTokensSummary(p) {
    var rows = modelRows(p)
    return rows.length > 0 ? rows[0].name + " · " + usage.formatTokenCount(rows[0].total) : ""
  }

  function settingOn(name, fallback) {
    var value = setting(name, fallback)
    if (value === true) return true
    if (value === false) return false
    var text = String(value).trim().toLowerCase()
    if (text === "on" || text === "true" || text === "1" || text === "yes") return true
    if (text === "off" || text === "false" || text === "0" || text === "no") return false
    return fallback === true
  }

  function providerGlyph() {
    var id = provider ? String(provider.providerId) : ""
    if (id === "grok") return "\ue904"
    if (id === "codex") return "\ue905"
    return "󱚣"
  }

  function barTooltip() {
    var name = provider ? provider.providerName : "Agents"
    if (remainingPct < 0) return name
    var text = name + " · " + remainingPct + "% left"
    if (headline && headline.resetAt) {
      var ms = new Date(headline.resetAt).getTime() - Date.now()
      if (isFinite(ms)) text += " · resets in " + formatDuration(ms)
    }
    return text
  }

  function selectProvider(index) {
    if (providers.length === 0) return
    var wrapped = ((index % providers.length) + providers.length) % providers.length
    selectedProviderId = providers[wrapped].providerId
  }

  readonly property int refreshCooldownMs: 60000
  readonly property bool refreshing: usage.busy
  readonly property double lastRefreshMs: agentLatestUpdatedMs()
  readonly property bool refreshOnCooldown: lastRefreshMs > 0 && (nowMs - lastRefreshMs) < refreshCooldownMs

  function agentLatestUpdatedMs() {
    var latest = 0
    var list = usage.agents || []
    for (var i = 0; i < list.length; i++) {
      var rec = list[i] && list[i].record
      if (!rec) continue
      var ms = Date.parse(String(rec.updatedAt || ""))
      if (isFinite(ms) && ms > latest) latest = ms
    }
    return latest
  }

  function refreshNow() {
    usage.refreshAll(true)
    usage.scheduleHistory()
  }

  function refreshFromButton() {
    if (refreshing || refreshOnCooldown) return
    refreshNow()
  }

  function launchAgent() {
    if (root.bar) root.bar.run("omarchy-agent --pick")
    root.close()
  }

  // ---------------------------------------------------------- accounts
  //
  // A provider's accounts, when it has any. The list arrives as a sequence
  // rather than a JS array once it has passed through a model, so it's
  // judged by its length.
  function providerAccounts(p) {
    return p && p.accounts && p.accounts.length > 0 ? p.accounts : []
  }

  // ------------------------------------------------------------ adding
  //
  // Adding a subscription happens right here: pick a provider, name it if
  // it's a second account, then sign in through the browser while the panel
  // follows omarchy-agent-account-add --events. The browser taking focus may
  // close the panel; the login carries on, and its result arrives as a
  // notification too.
  //
  // All of it rides on `omarchy agent account`, which a release older than
  // the one that introduced accounts doesn't ship. There usage.accountTools
  // stays false and none of these controls are offered.

  readonly property var addProviders: [
    { providerId: "claude", providerName: "Claude Code" },
    { providerId: "codex", providerName: "Codex" },
    { providerId: "grok", providerName: "Grok" }
  ]
  property string addStage: ""
  property string addProvider: ""
  property var addChecks: ({})
  property string addStatus: ""
  property string addCode: ""
  property string addUrl: ""
  property bool addNeedsPaste: false
  property string addResult: ""
  // Whether the sign-in in progress opened a private window, so reopening its
  // page does too.
  property bool addPrivate: false

  function addProviderName(id) {
    for (var i = 0; i < addProviders.length; i++)
      if (addProviders[i].providerId === id) return addProviders[i].providerName
    return id
  }

  function addAccount() {
    if (addStage === "running" || !usage.accountTools) return
    addStage = "pick"
    addChecks = ({})
    if (!checkProcess.running) checkProcess.running = true
  }

  function chooseAddProvider(id) {
    var state = addChecks[id] || ""
    if (state === "") return
    addProvider = id
    if (state === "additional") addStage = "name"
    else startAdd("")
  }

  function startAdd(label) {
    addPrivate = (addChecks[addProvider] || "") === "additional"
    addStatus = "Starting…"
    addCode = ""
    addUrl = ""
    // Claude's login offers pasting a code back whenever its page shows one,
    // and its prompt for it has no newline to read it by, so the field is
    // there from the start.
    addNeedsPaste = addProvider === "claude"
    addResult = ""
    addStage = "running"
    addProcess.command = ["omarchy-agent-account-add", "--events", addProvider].concat(label !== "" ? [label] : [])
    addProcess.running = true
  }

  function cancelAdd() {
    if (addProcess.running) addProcess.signal(15)
    addStage = ""
    root.focusKeys()
  }

  // A first sign-in keeps saying so until its limits arrive, rather than
  // flashing the choices again while the record is written.
  onBlankSlateChanged: if (!blankSlate && addStage === "done") addStage = ""

  function submitPaste(code) {
    if (!addProcess.running || code.trim() === "") return
    addProcess.write(code.trim() + "\n")
    addStatus = "Checking the code…"
  }

  // The add command's own lines are tagged; everything else is the CLI
  // talking, and only two things in it matter here: a code to confirm in the
  // browser (Grok), and an invitation to paste one back (Claude).
  function handleAddLine(line) {
    var text = String(line).replace(/\u001b\[[0-9;]*m/g, "")
    var tagged = text.match(/^@@omarchy (status|done|error) (.*)$/)
    if (tagged) {
      if (tagged[1] === "status") {
        addStatus = tagged[2]
      } else {
        addResult = tagged[2]
        addStage = tagged[1]
        if (tagged[1] === "done") {
          usage.refreshLimits()
          addDoneTimer.restart()
          // Nothing to show yet means the sign-in is what counts as set up.
          if (providers.length === 0 && !checkProcess.running) {
            addChecks = ({})
            checkProcess.running = true
          }
        }
      }
      return
    }
    var code = text.match(/^\s*([A-Z0-9]{4}-[A-Z0-9]{4})\s*$/)
    if (code) addCode = code[1]
    if (/paste code/i.test(text)) addNeedsPaste = true
    var url = text.match(/(https:\/\/\S+)/)
    if (url && addUrl === "") addUrl = url[1]
  }

  function reopenSignIn() {
    if (addUrl === "") return
    Util.execArgv(addPrivate ? ["omarchy-launch-browser", "--private", addUrl] : ["omarchy-launch-browser", addUrl])
  }

  // A few ways into making Omarchy your own, handed to the default agent.
  readonly property var starterPrompts: [
    { glyph: "󰏘", label: "Theme", prompt: "Make me a new Omarchy theme. Ask me what look or inspiration I have in mind, then build it following the Omarchy skill's theming guide and switch to it." },
    { glyph: "󰐱", label: "Plugin", prompt: "Make me a new Omarchy shell plugin. Ask me what I'd like it to do, then build it following the Omarchy skill's plugin guide and enable it." },
    { glyph: "󰣆", label: "App", prompt: "Make me a new app for my Omarchy desktop. Ask me what it should do, then build it following the omarchy-app skill and install it so it shows up in the app launcher." }
  ]

  function startPrompt(prompt) {
    root.close()
    Util.execArgv(["omarchy-agent-prompt", prompt])
  }

  function renameAccount(p, account, label) {
    if (!p || !account) return
    Util.execArgv(["omarchy-agent-account-rename", p.providerId, String(account.id), label])
  }

  function useAccount(p, account) {
    if (!p || !account || account.active) return
    Util.execArgv(["omarchy-agent-account-use", p.providerId, String(account.id)])
  }

  function autoSwitchFor(p) {
    return !!p && !!p.accountSwitch && p.accountSwitch.mode === "auto"
  }

  function switchThreshold(p) {
    return p && p.accountSwitch ? Number(p.accountSwitch.threshold || 95) : 95
  }

  // The record is collected again through this plugin's own runner, so a
  // provider whose collector it bundles keeps that collector's record.
  function setSwitchMode(p, mode) {
    if (!p || providerAccounts(p).length < 2 || mode === (autoSwitchFor(p) ? "auto" : "manual")) return
    Util.execArgv(["bash", "-c", 'omarchy-agent-account-mode "$1" "$2" >/dev/null && shift 2 && exec "$@"',
                   "omarchy-agent-account-mode", p.providerId, mode].concat(usage.updateCommand("limits", [p.providerId])))
  }

  // `m` flips autoswitch for the picked account's provider, or the first
  // provider with several accounts when nothing is picked.
  function toggleSwitchMode() {
    var p = pickedEntry ? pickedEntry.provider : (accountEntries.length > 0 ? accountEntries[0].provider : null)
    if (p) setSwitchMode(p, autoSwitchFor(p) ? "manual" : "auto")
  }

  function activateSelection() {
    var target = keyTarget
    if (!target) refreshNow()
    else if (target.kind === "add") addStage !== "" ? cancelAdd() : addAccount()
    else if (target.kind === "choice") chooseAddProvider(addProviders[target.index].providerId)
    else if (target.kind === "launch") launchAgent()
    else if (target.kind === "starter") startPrompt(starterPrompts[target.index].prompt)
    else if (target.kind === "providerSignin") signInAgain(providers[target.index], null)
    else if (target.kind === "days" || target.kind === "models") toggleTokenSection(providers[target.index], target.kind)
    else if (target.kind === "signin") signInAgain(pickedEntry.provider, pickedEntry.account)
    else if (target.kind === "autoswitch") setSwitchMode(pickedEntry.provider, autoSwitchFor(pickedEntry.provider) ? "manual" : "auto")
    else if (pickedEntry && !pickedEntry.account.active) useAccount(pickedEntry.provider, pickedEntry.account)
  }

  function isPicked(p, account) {
    return !!pickedEntry && !!p && !!account
      && pickedEntry.provider.providerId === p.providerId && pickedEntry.account.id === account.id
  }

  // Hands the keyboard back to the panel after an inline edit.
  function focusKeys() {
    keyCatcher.forceActiveFocus()
  }

  function accountDetail(account) {
    var parts = []
    if (String(account.plan || "") !== "") parts.push(account.plan)
    if (account.resetCredits && Number(account.resetCredits.available) > 0)
      parts.push(account.resetCredits.available + " free reset" + (Number(account.resetCredits.available) === 1 ? "" : "s"))
    return parts.join(" · ")
  }

  // A lapsed or missing sign-in is something you can fix from here; any other
  // trouble is only reported.
  function needsSignIn(item) {
    var status = String(item && item.usageStatusText || "")
    return status === "Sign-in expired" || status === "Waiting for auth"
  }

  // Only the agents `omarchy agent account` knows can be signed in from the
  // panel. The others (Cursor, Antigravity, …) sign in through their own app,
  // and keep saying how in their help line.
  function canSignIn(p) {
    if (!p || !usage.accountTools) return false
    for (var i = 0; i < addProviders.length; i++)
      if (addProviders[i].providerId === p.providerId) return true
    return false
  }

  function signInOffered(p) {
    return providerAccounts(p).length < 2 && needsSignIn(p) && canSignIn(p)
  }

  function otherTrouble(item) {
    var status = String(item && item.usageStatusText || "")
    return status !== "" && status !== "Limits paused" && !needsSignIn(item) ? status : ""
  }

  function pausedWithoutLimits(item) {
    return !!item && item.usageStatusText === "Limits paused" && limitWindows(item).length === 0
  }

  // What a single-account agent says under its name when something is off
  // and the Sign-in required link isn't the answer: the collector's help,
  // or failing that its status.
  function providerNotice(p) {
    if (!p || signInOffered(p) || String(p.usageStatusText || "") === "Limits paused") return ""
    return String(p.authHelpText || p.usageStatusText || "")
  }

  // Sign an account that's already here in again, following along in the
  // add view just like adding one.
  function signInAgain(p, account) {
    if (!p || addStage === "running" || !canSignIn(p)) return
    addProvider = p.providerId
    addPrivate = !!account && account.primary !== true
    addStatus = "Starting…"
    addCode = ""
    addUrl = ""
    // Claude's login offers pasting a code back whenever its page shows one,
    // and its prompt for it has no newline to read it by, so the field is
    // there from the start.
    addNeedsPaste = addProvider === "claude"
    addResult = ""
    addStage = "running"
    addProcess.command = ["omarchy-agent-account-add", "--events", "--reauth",
      account && account.primary !== true ? String(account.id) : ":primary", p.providerId]
    addProcess.running = true
  }

  function resetCreditsText(credits) {
    if (!credits || !(Number(credits.available) > 0)) return ""
    var count = Number(credits.available)
    var text = count + " free reset" + (count === 1 ? "" : "s")
    var expires = new Date(String(credits.nextExpiresAt || "")).getTime()
    if (isFinite(expires) && expires > nowMs) text += " · next expires in " + formatDuration(expires - nowMs)
    return text
  }

  function planLabel(p) {
    var tier = String(p && p.tierLabel || "")
    return tier === "" ? "" : tier.charAt(0).toUpperCase() + tier.slice(1)
  }

  // ---------------------------------------------------------------- limits
  //
  // Both providers report the same two shapes: a short rolling session window
  // and a long weekly one. Everything below normalizes them into one record so
  // the meters and the hero speak a single language.

  // Claude spells its windows out ("Session (5-hour)"), Codex abbreviates
  // them ("5h window", "30m window"). Both have to land on the same record.
  function windowIsLong(text) {
    return text.indexOf("week") >= 0 || text.indexOf("7-day") >= 0 || text.indexOf("seven") >= 0
      || text.indexOf("month") >= 0 || text.indexOf("30-day") >= 0
  }

  function windowSpanMs(label) {
    var text = String(label || "").toLowerCase()
    if (text.indexOf("month") >= 0 || text.indexOf("30-day") >= 0) return 30 * 24 * 3600 * 1000
    if (windowIsLong(text)) return 7 * 24 * 3600 * 1000
    var hours = text.match(/(\d+)\s*-?\s*h(?:our)?\b/)
    if (hours) return Number(hours[1]) * 3600 * 1000
    var minutes = text.match(/(\d+)\s*-?\s*m(?:in(?:ute)?s?)?\b/)
    if (minutes) return Number(minutes[1]) * 60 * 1000
    return 0
  }

  function windowTitle(label) {
    var text = String(label || "").toLowerCase()
    if (text.indexOf("month") >= 0) return "Monthly"
    if (windowIsLong(text)) return "Weekly"
    if (text.indexOf("session") >= 0 || windowSpanMs(label) > 0) return "Session"
    var plain = String(label || "").replace(/\s*\(.*\)\s*/, "").trim()
    return plain === "" ? "Limit" : plain
  }

  // A collector that already knows which window a limit belongs to says so,
  // and that beats reading it back out of the label: a model-scoped limit is
  // titled after its model, and a name like "Opus 5 (1M context)" would parse
  // as a one-minute window.
  function limitWindow(label, percent, resetAt, title, startAt, display) {
    // A window whose reset has passed has started over empty, whatever the
    // last check said, and its old start no longer describes it.
    var reset = new Date(String(resetAt || "")).getTime()
    var expired = isFinite(reset) && reset <= root.nowMs
    return {
      title: String(title || "") !== "" ? String(title) : windowTitle(label),
      percent: expired ? 0 : Number(percent),
      resetAt: expired ? "" : String(resetAt || ""),
      startsAt: expired ? "" : String(startAt || ""),
      display: String(display || "remaining")
    }
  }

  function limitWindows(p) {
    if (!p) return []
    var out = []
    var list = p.limits || []
    for (var i = 0; i < list.length; i++) {
      var entry = list[i] || {}
      var percent = Number(entry.percent)
      if (percent >= 0)
        out.push(limitWindow(entry.label, percent, entry.resetsAt, entry.title, entry.startsAt, entry.display))
    }
    return out
  }

  // The window that decides how much room is left — the fullest one, since
  // that is what stops the next prompt.
  function bindingWindow(p) {
    var windows = limitWindows(p)
    var best = null
    for (var i = 0; i < windows.length; i++) {
      if (!best || windows[i].percent > best.percent) best = windows[i]
    }
    return best
  }

  function resetMsFor(w) {
    if (!w || w.resetAt === "") return -1
    var ms = new Date(w.resetAt).getTime()
    return isFinite(ms) ? ms - root.nowMs : -1
  }

  function inferredWindowSpanMs(w) {
    var title = String((w && w.title) || "")
    // A model-scoped window ("Fable Weekly") runs on the clock of the window
    // it's named for.
    var scoped = title.match(/ (Session|Weekly|Monthly|Daily)$/)
    if (scoped) title = scoped[1]
    if (title === "Weekly") return 7 * 24 * 3600 * 1000
    if (title === "Monthly") return 30 * 24 * 3600 * 1000
    if (title === "Daily") return 24 * 3600 * 1000
    if (title === "Session") return 5 * 3600 * 1000
    return 0
  }

  // CodexBar even-burn pace: expected used = elapsed fraction of the window.
  function windowStartMs(w) {
    if (!w) return -1
    if (w.startsAt) {
      var started = new Date(w.startsAt).getTime()
      if (isFinite(started)) return started
    }
    var end = w.resetAt ? new Date(w.resetAt).getTime() : NaN
    var span = inferredWindowSpanMs(w)
    return isFinite(end) && span > 0 ? end - span : -1
  }

  function windowElapsed(w) {
    var start = windowStartMs(w)
    var end = w && w.resetAt ? new Date(w.resetAt).getTime() : NaN
    if (start < 0 || !(end > start)) return -1
    return clamp((root.nowMs - start) / (end - start), 0, 1)
  }

  // Vertical tick sits at expected remaining (1 - elapsed) on a countdown bar.
  function paceRemaining(w) {
    var elapsed = windowElapsed(w)
    if (elapsed < 0.03) return -1
    return elapsed >= 0 ? clamp(1 - elapsed, 0, 1) : -1
  }

  // actualUsed - expectedUsed. Positive = deficit, negative = reserve.
  function paceDelta(w) {
    var elapsed = windowElapsed(w)
    if (elapsed < 0.03 || !w || !(w.percent >= 0)) return null
    return Number(w.percent) - elapsed
  }

  function runsOutMs(w) {
    var elapsed = windowElapsed(w)
    var used = w ? Number(w.percent) : NaN
    var start = windowStartMs(w)
    if (elapsed <= 0 || !(used > 0) || start < 0) return -1
    var remaining = 1 - used
    if (remaining <= 0) return 0
    return remaining / (used / (root.nowMs - start))
  }

  function paceCaption(w) {
    var delta = paceDelta(w)
    if (delta === null) return ""
    var resetMs = resetMsFor(w)
    var emptyMs = runsOutMs(w)
    if (Math.abs(delta) < 0.02) return "On pace · lasts until reset"
    if (delta > 0) {
      var when = emptyMs >= 0 && (resetMs < 0 || emptyMs < resetMs)
        ? "runs out in " + formatDuration(emptyMs)
        : "lasts until reset"
      return Math.round(delta * 100) + "% in deficit · " + when
    }
    return Math.round(-delta * 100) + "% in reserve · lasts until reset"
  }

  function formatDuration(ms) {
    if (!(ms > 0)) return "now"
    var minutes = Math.floor(ms / 60000)
    var hours = Math.floor(minutes / 60)
    var days = Math.floor(hours / 24)
    if (days > 0) return days + "d " + (hours % 24) + "h"
    if (hours > 0) return hours + "h " + (minutes % 60) + "m"
    return Math.max(1, minutes) + "m"
  }

  function parseHistory(content) {
    try {
      var parsed = JSON.parse(String(content || ""))
      return parsed && typeof parsed === "object" ? parsed : null
    } catch (e) {
      return null
    }
  }

  // Charts ignore 5h/session pools. A window counts once it is a week long
  // (title or startsAt..resetsAt), so monthly Cursor pools still plot.
  function remainingWindowSpanMs(title, startsAt, resetsAt) {
    var start = remainingParseMs(startsAt)
    var reset = remainingParseMs(resetsAt)
    if (isFinite(start) && isFinite(reset) && reset > start) return reset - start
    var span = root.windowSpanMs(title)
    return span > 0 ? span : 0
  }

  function remainingSeriesIsLong(entry) {
    if (!entry) return false
    var title = String(entry.title || entry.id || "")
    var text = title.toLowerCase()
    if (root.windowIsLong(text)) return true
    if (text.indexOf("session") >= 0 || text.indexOf("5h") >= 0 || text.indexOf("5-hour") >= 0
        || text.indexOf("30m") >= 0 || text.indexOf("hourly") >= 0 || text.indexOf("daily") >= 0)
      return false
    var raw = entry.points || []
    for (var i = raw.length - 1; i >= 0; i--) {
      var span = remainingWindowSpanMs(title, raw[i] && raw[i].startsAt, raw[i] && raw[i].resetsAt)
      if (span >= root.remainingMinWindowMs) return true
    }
    return remainingWindowSpanMs(title, "", "") >= root.remainingMinWindowMs
  }

  function remainingChartSeries(series) {
    var list = series || []
    var out = []
    for (var i = 0; i < list.length; i++)
      if (remainingSeriesIsLong(list[i])) out.push(list[i])
    return out
  }

  function remainingSeriesFor(provider) {
    var id = provider ? String(provider.providerId || "") : ""
    if (id !== "grok" && id !== "grokbot" && id !== "cursor" && id !== "codex" && id !== "antigravity") return []
    var hist = id === "grok" ? root.grokRemaining
      : id === "grokbot" ? root.grokbotRemaining
      : id === "cursor" ? root.cursorRemaining
      : id === "antigravity" ? root.antigravityRemaining
      : root.codexRemaining
    if (hist && Array.isArray(hist.series) && hist.series.length > 0)
      return remainingChartSeries(hist.series)
    if (provider && Array.isArray(provider.remainingSeries) && provider.remainingSeries.length > 0)
      return remainingChartSeries(provider.remainingSeries)
    return remainingChartSeries(root.syntheticSeries(provider))
  }

  function syntheticSeries(provider) {
    var windows = root.limitWindows(provider)
    var nowIso = new Date(root.nowMs).toISOString()
    var series = []
    for (var i = 0; i < windows.length; i++) {
      var w = windows[i]
      if (!w || !(w.percent >= 0)) continue
      var start = w.startsAt || ""
      if (!start && w.resetAt) {
        var end = root.remainingParseMs(w.resetAt)
        var span = root.inferredWindowSpanMs(w)
        if (isFinite(end) && span > 0) start = new Date(end - span).toISOString()
      }
      series.push({
        id: String(w.title || ("limit-" + i)),
        title: String(w.title || "Limit"),
        points: [{
          t: start || nowIso,
          remaining: root.clamp(1 - Number(w.percent), 0, 1),
          until: nowIso,
          startsAt: start,
          resetsAt: w.resetAt || ""
        }]
      })
    }
    return series
  }

  function remainingCss(c) {
    if (!c) return "#ffffff"
    var r = Math.round(Number(c.r) * 255)
    var g = Math.round(Number(c.g) * 255)
    var b = Math.round(Number(c.b) * 255)
    var a = (c.a === undefined || c.a === null) ? 1 : Number(c.a)
    return "rgba(" + r + "," + g + "," + b + "," + a + ")"
  }

  function remainingParseMs(value) {
    var text = String(value || "").trim()
    if (text === "") return NaN
    text = text.replace(/(\.\d{3})\d+/, "$1")
    text = text.replace(/([+-]\d{2}):(\d{2})$/, "$1$2")
    var ms = Date.parse(text)
    if (isFinite(ms)) return ms
    var d = new Date(String(value || ""))
    return isNaN(d.getTime()) ? NaN : d.getTime()
  }

  function remainingExpand(entry, nowMs) {
    var pts = []
    var raw = entry && entry.points ? entry.points : []
    if (!isFinite(nowMs)) nowMs = Date.now()
    for (var i = 0; i < raw.length; i++) {
      var p = raw[i] || {}
      var t = remainingParseMs(p.t)
      var y = Number(p.remaining)
      if (!isFinite(t) || !isFinite(y) || t > nowMs) continue
      y = root.clamp(y, 0, 1)
      var winStart = remainingParseMs(p.startsAt)
      var winReset = remainingParseMs(p.resetsAt)
      pts.push({ t: t, y: y, startsAt: winStart, resetsAt: winReset })
      var until = remainingParseMs(p.until)
      if (isFinite(until) && until > t) {
        if (until > nowMs) until = nowMs
        if (until > t) pts.push({ t: until, y: y, startsAt: winStart, resetsAt: winReset })
      }
    }
    if (pts.length === 0) return pts
    // Hold the last known leftover through now. Do not backfill from the
    // window start — there is no sample there yet.
    if (pts[pts.length - 1].t < nowMs)
      pts.push({
        t: nowMs,
        y: pts[pts.length - 1].y,
        startsAt: pts[pts.length - 1].startsAt,
        resetsAt: pts[pts.length - 1].resetsAt
      })
    return pts
  }

  function remainingClipToWindow(pts, tMin, tMax) {
    if (!pts || pts.length === 0) return []
    if (!(tMax > tMin)) return pts
    var out = []
    var hold = null
    for (var i = 0; i < pts.length; i++) {
      var t = pts[i].t
      var y = pts[i].y
      if (t < tMin) {
        // Only carry a plateau into the visible window when it belongs to
        // the same quota cycle. A previous cycle's leftover must not paint
        // across the new startsAt.
        var reset = pts[i].resetsAt
        var start = pts[i].startsAt
        var covers = (!isFinite(reset) || reset > tMin) && (!isFinite(start) || start <= tMin)
        if (covers) hold = y
        continue
      }
      if (t > tMax) {
        if (out.length === 0 && hold !== null)
          out.push({ t: tMin, y: hold })
        if (out.length > 0 && out[out.length - 1].t < tMax)
          out.push({ t: tMax, y: out[out.length - 1].y })
        else if (out.length === 0 && hold !== null)
          out.push({ t: tMax, y: hold })
        return out
      }
      if (out.length === 0 && hold !== null && t > tMin)
        out.push({ t: tMin, y: hold })
      out.push({ t: t, y: y })
    }
    if (out.length === 0 && hold !== null) {
      out.push({ t: tMin, y: hold })
      if (tMax > tMin) out.push({ t: tMax, y: hold })
    }
    return out
  }

  // Floor/ceil onto local :00/:15/:30/:45 so the axis labels land on a clock tick.
  function remainingSnapQuarter(ms, ceil) {
    var d = new Date(ms)
    if (isNaN(d.getTime())) return ms
    var remainder = d.getMinutes() * 60000 + d.getSeconds() * 1000 + d.getMilliseconds()
    var q = 15 * 60000
    var hourStart = d.getTime() - remainder
    if (ceil) return remainder === 0 ? hourStart : hourStart + Math.ceil(remainder / q) * q
    return hourStart + Math.floor(remainder / q) * q
  }

  // Current 7d+ quota window: newest startsAt that is not in the future.
  function remainingCurrentWindow(series, nowMs) {
    if (!isFinite(nowMs)) nowMs = Date.now()
    var start = NaN, reset = NaN
    var list = series || []
    for (var s = 0; s < list.length; s++) {
      var raw = list[s] && list[s].points ? list[s].points : []
      for (var i = 0; i < raw.length; i++) {
        var p = raw[i] || {}
        var winStart = remainingParseMs(p.startsAt)
        var winReset = remainingParseMs(p.resetsAt)
        if (!isFinite(winStart) || winStart > nowMs) continue
        if (!isFinite(start) || winStart >= start) {
          start = winStart
          if (isFinite(winReset)) reset = winReset
        }
      }
    }
    return { start: start, reset: reset }
  }

  function remainingSoonestReset(series, nowMs) {
    var window = remainingCurrentWindow(series, nowMs)
    return isFinite(window.reset) ? window.reset : NaN
  }

  // First sample in the current cycle (t >= startsAt), not the window start.
  function remainingFirstValueMs(series, afterMs, nowMs) {
    if (!isFinite(nowMs)) nowMs = Date.now()
    if (!isFinite(afterMs)) afterMs = -Infinity
    var first = Infinity
    var list = series || []
    for (var s = 0; s < list.length; s++) {
      var raw = list[s] && list[s].points ? list[s].points : []
      for (var i = 0; i < raw.length; i++) {
        var t = remainingParseMs(raw[i] && raw[i].t)
        if (!isFinite(t) || t < afterMs || t > nowMs) continue
        if (t < first) first = t
      }
    }
    return isFinite(first) ? first : NaN
  }

  // days: 2-day span. Start special (quota start inside lookback) moves
  // tMin to the quarter-hour at or before the first sample. End special
  // (reset within 2 days) moves tMax to the reset. Exactly one special
  // keeps width = 2 days; both drop the width constraint. cycle: first
  // sample (snapped back to a quarter-hour) .. resetsAt.
  // Data still stops at now either way — future hours stay empty.
  function remainingBounds(series, nowMs, mode) {
    if (!isFinite(nowMs)) nowMs = Date.now()
    var window = remainingCurrentWindow(series, nowMs)
    var first = remainingFirstValueMs(series, window.start, nowMs)
    var day = 86400000
    if (mode === "cycle") {
      var cMin = isFinite(first) ? remainingSnapQuarter(first, false)
        : (isFinite(window.start) ? window.start : nowMs - 3600 * 1000)
      var cMax = isFinite(window.reset) && window.reset > cMin
        ? window.reset
        : Math.max(nowMs, cMin + 3600 * 1000)
      if (cMax < nowMs) cMax = nowMs
      return { min: cMin, max: cMax }
    }
    var tMin0 = remainingSnapQuarter(nowMs - 1.8 * day, false)
    var tMax0 = remainingSnapQuarter(nowMs + 0.2 * day, true)
    var startSpecial = isFinite(window.start) && window.start > tMin0 && window.start <= nowMs
    var endSpecial = isFinite(window.reset) && window.reset > nowMs && window.reset - nowMs < 2 * day
    var edge = remainingSnapQuarter(isFinite(first) ? first : window.start, false)
    var tMin, tMax
    if (startSpecial && endSpecial) {
      tMin = isFinite(edge) ? edge : tMin0
      tMax = window.reset
    } else if (startSpecial) {
      tMin = isFinite(edge) ? edge : tMin0
      tMax = tMin + 2 * day
    } else if (endSpecial) {
      tMax = window.reset
      tMin = remainingSnapQuarter(tMax - 2 * day, false)
    } else {
      tMin = tMin0
      tMax = tMax0
    }
    if (!(tMax > tMin)) tMax = tMin + 15 * 60000
    if (tMax < nowMs) tMax = remainingSnapQuarter(nowMs, true)
    return { min: tMin, max: tMax }
  }

  function remainingTick(ms) {
    var d = new Date(ms)
    if (isNaN(d.getTime())) return ""
    function pad(n) { return n < 10 ? "0" + n : "" + n }
    return (d.getMonth() + 1) + "/" + d.getDate() + " " + pad(d.getHours()) + ":" + pad(d.getMinutes())
  }

  // Read the Y value from the same clipped, linearly connected points that
  // are painted below. A sloped segment between polls is an estimate; flat
  // plateaus are known because history.py stores their t..until interval.
  function remainingValueAt(entry, targetMs, nowMs, bounds) {
    if (!entry || !bounds || !isFinite(targetMs) || !isFinite(nowMs)) return null
    var dataMax = Math.min(nowMs, Number(bounds.max))
    if (targetMs > dataMax || targetMs < Number(bounds.min)) return null
    var pts = remainingClipToWindow(remainingExpand(entry, nowMs), Number(bounds.min), dataMax)
    if (pts.length === 0 || targetMs < pts[0].t) return null
    var prev = pts[0]
    for (var i = 1; i < pts.length; i++) {
      var next = pts[i]
      if (targetMs > next.t) {
        prev = next
        continue
      }
      if (next.t <= prev.t)
        return { y: next.y, estimated: false }
      var ratio = root.clamp((targetMs - prev.t) / (next.t - prev.t), 0, 1)
      return {
        y: prev.y + (next.y - prev.y) * ratio,
        estimated: Math.abs(next.y - prev.y) > 0.00005 && ratio > 0 && ratio < 1
      }
    }
    return targetMs <= prev.t ? { y: prev.y, estimated: false } : null
  }

  function remainingValuesAt(series, targetMs, nowMs, bounds) {
    var values = []
    var list = series || []
    for (var i = 0; i < list.length; i++) {
      var value = remainingValueAt(list[i], targetMs, nowMs, bounds)
      if (!value) continue
      values.push({
        series: i,
        title: String((list[i] && (list[i].title || list[i].id)) || ("Limit " + (i + 1))),
        y: value.y,
        estimated: value.estimated
      })
    }
    return values
  }

  function remainingPercentText(value) {
    var pct = Math.round(root.clamp(Number(value), 0, 1) * 1000) / 10
    return Math.abs(pct - Math.round(pct)) < 0.05 ? Math.round(pct) + "%" : pct.toFixed(1) + "%"
  }

  function remainingChartSvg(series, w, h, nowMs) {
    w = Math.max(240, Math.round(Number(w) || 240))
    h = Math.max(60, Math.round(Number(h) || 92))
    if (!isFinite(nowMs)) nowMs = Date.now()
    var left = 36, right = 8, top = 8, bottom = 8
    var plotW = Math.max(1, w - left - right)
    var plotH = Math.max(1, h - top - bottom)
    var bounds = remainingBounds(series, nowMs, root.remainingAxis)
    var tMin = bounds.min, tMax = bounds.max
    var span = tMax - tMin
    if (!(span > 0)) span = 1
    var ink = remainingCss(root.foreground)
    var dim = remainingCss(root.dim)
    var grid = remainingCss(root.alpha(root.foreground, 0.2))
    function xAt(t) { return left + plotW * ((t - tMin) / span) }
    function yAt(y) { return top + plotH * (1 - y) }
    var svg = '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 ' + w + ' ' + h + '">'
    var marks = [0, 0.5, 1]
    var labels = ["0%", "50%", "100%"]
    for (var m = 0; m < marks.length; m++) {
      var gy = yAt(marks[m]).toFixed(1)
      svg += '<line x1="' + left + '" y1="' + gy + '" x2="' + (left + plotW) + '" y2="' + gy + '" stroke="' + grid + '" stroke-width="1"/>'
      svg += '<text x="' + (left - 4) + '" y="' + (Number(gy) + 3) + '" text-anchor="end" fill="' + dim + '" font-size="9">' + labels[m] + '</text>'
    }
    var list = series || []
    for (var s = 0; s < list.length; s++) {
      var pts = remainingExpand(list[s], nowMs)
      if (pts.length === 0) continue
      var d = ""
      for (var i = 0; i < pts.length; i++)
        d += (i === 0 ? "M" : "L") + xAt(pts[i].t).toFixed(1) + " " + yAt(pts[i].y).toFixed(1) + " "
      var stroke = s === 0 ? ink : remainingCss(root.alpha(root.foreground, 0.5))
      var dash = s === 0 ? "" : ' stroke-dasharray="4 3"'
      svg += '<path d="' + d + '" fill="none" stroke="' + stroke + '" stroke-width="1.6" stroke-linejoin="round" stroke-linecap="round"' + dash + '/>'
    }
    svg += "</svg>"
    return "data:image/svg+xml;utf8," + encodeURIComponent(svg)
  }

  function remainingPlotLayout(series, width, height, nowMs, mode) {
    var w = Math.max(1, Number(width) || 1)
    var h = Math.max(1, Number(height) || 1)
    var left = 36, right = 8, top = 10, bottom = 10
    var plotW = Math.max(1, w - left - right)
    var plotH = Math.max(1, h - top - bottom)
    var yZero = top + plotH
    if (!isFinite(nowMs)) nowMs = Date.now()
    var bounds = remainingBounds(series, nowMs, mode)
    var span = bounds.max - bounds.min
    if (!(span > 0)) span = 1
    // One closed area path per series (first sample .. last), not per-segment
    // rectangles — adjacent rect seams show up as fine vertical comb lines.
    var areas = []
    var lines = []
    var dots = []
    var nows = []
    var list = series || []
    function mapX(t) { return left + plotW * ((t - bounds.min) / span) }
    function mapY(y) { return top + plotH * (1 - y) }
    var xNow = mapX(Math.min(Math.max(nowMs, bounds.min), bounds.max))
    var dataMax = Math.min(nowMs, bounds.max)
    for (var s = 0; s < list.length; s++) {
      var pts = remainingClipToWindow(remainingExpand(list[s], nowMs), bounds.min, dataMax)
      if (pts.length === 1)
        pts = [pts[0], { t: Math.min(nowMs, dataMax), y: pts[0].y }]
      if (pts.length === 0) continue
      var lineBefore = lines.length
      var areaPts = []
      for (var i = 0; i < pts.length; i++) {
        var x = Math.min(mapX(pts[i].t), xNow)
        var y = mapY(pts[i].y)
        areaPts.push({ x: x, y: y })
        if (i > 0) {
          var x0 = Math.min(mapX(pts[i - 1].t), xNow)
          var y0 = mapY(pts[i - 1].y)
          var dx = x - x0
          var dy = y - y0
          var len = Math.sqrt(dx * dx + dy * dy)
          if (len >= 0.8) {
            lines.push({
              x: x0,
              y: y0 - 0.5,
              width: len,
              rotation: Math.atan2(dy, dx) * 180 / Math.PI,
              series: s
            })
          }
        }
        if (i === 0 || i === pts.length - 1 || pts[i].y !== pts[i - 1].y) {
          dots.push({ x: x - 0.6, y: y - 0.6, series: s })
        }
      }
      if (lines.length === lineBefore) {
        var sx = Math.min(mapX(pts[0].t), xNow)
        var sy = mapY(pts[0].y)
        var sw = Math.max(0.8, xNow - sx)
        areaPts = [{ x: sx, y: sy }, { x: sx + sw, y: sy }]
        lines.push({ x: sx, y: sy - 0.5, width: sw, rotation: 0, series: s })
        dots.push({ x: sx - 0.6, y: sy - 0.6, series: s })
      }
      if (areaPts.length >= 2)
        areas.push({ series: s, points: areaPts })
      var last = pts[pts.length - 1]
      var ny = mapY(last.y)
      var dash = 3, gap = 3, yDash = ny
      while (yDash < yZero) {
        var segH = Math.min(dash, yZero - yDash)
        if (segH >= 0.6) {
          nows.push({
            x: xNow,
            y: yDash,
            width: 1,
            height: segH,
            series: s
          })
        }
        yDash += dash + gap
      }
    }
    var resets = []
    var resetX = -1
    var resetAt = remainingSoonestReset(series, nowMs)
    if (isFinite(resetAt) && resetAt >= bounds.min && resetAt <= bounds.max) {
      resetX = Math.min(Math.max(mapX(resetAt), left), left + plotW - 1)
      var yR = top, dashR = 2, gapR = 2
      while (yR < yZero) {
        var hR = Math.min(dashR, yZero - yR)
        if (hR >= 0.6)
          resets.push({ x: resetX, y: yR, width: 1, height: hR })
        yR += dashR + gapR
      }
    }
    var paces = []
    var win = remainingCurrentWindow(series, nowMs)
    if (isFinite(win.start) && isFinite(win.reset) && win.reset > win.start) {
      var tPace0 = Math.max(bounds.min, win.start)
      var tPace1 = Math.min(bounds.max, win.reset)
      if (tPace1 > tPace0) {
        var yPace0 = root.clamp(1 - (tPace0 - win.start) / (win.reset - win.start), 0, 1)
        var yPace1 = root.clamp(1 - (tPace1 - win.start) / (win.reset - win.start), 0, 1)
        var px0 = mapX(tPace0)
        var px1 = mapX(tPace1)
        var py0 = mapY(yPace0)
        var py1 = mapY(yPace1)
        var pdx = px1 - px0
        var pdy = py1 - py0
        var plen = Math.sqrt(pdx * pdx + pdy * pdy)
        if (plen >= 2) {
          var ux = pdx / plen
          var uy = pdy / plen
          var dashP = 4, gapP = 3, pos = 0
          var rot = Math.atan2(pdy, pdx) * 180 / Math.PI
          while (pos < plen) {
            var segP = Math.min(dashP, plen - pos)
            if (segP >= 0.8) {
              var along = (pos + segP / 2) / plen
              var tDash = tPace0 + along * (tPace1 - tPace0)
              // Opaque at the left / past, fade toward reset and anything after now.
              var aAlong = 0.9 * (1 - along) + 0.16 * along
              var aFuture = 1
              if (tDash > nowMs && tPace1 > nowMs)
                aFuture = 0.28 + 0.72 * (1 - (tDash - nowMs) / (tPace1 - nowMs))
              paces.push({
                x: px0 + ux * pos,
                y: py0 + uy * pos - 0.5,
                width: segP,
                rotation: rot,
                alpha: root.clamp(aAlong * aFuture, 0.1, 0.92)
              })
            }
            pos += dashP + gapP
          }
        }
      }
    }
    return { areas: areas, yZero: yZero, lines: lines, dots: dots, nows: nows, nowX: xNow, resets: resets, resetX: resetX, paces: paces }
  }

  // ---------------------------------------------------------------- balance
  //
  // Prepaid agents report a credit ledger instead of rate-limit windows: the
  // record's balance object carries remaining, funded, and spent amounts.

  // A prepaid account runs low the way a subscription window fills up: the
  // last 10% of the funded credits lights the same alarm.
  function balanceLow(b) {
    return !!b && b.funded > 0 && b.remaining / b.funded <= 0.1
  }

  function currencyPrefix(currency) {
    var code = String(currency || "USD").toUpperCase()
    if (code === "USD") return "$"
    if (code === "EUR") return "€"
    if (code === "GBP") return "£"
    return code + " "
  }

  function formatMoney(value, currency) {
    var amount = Number(value)
    if (!isFinite(amount)) amount = 0
    return currencyPrefix(currency) + amount.toFixed(2)
  }

  function balanceDetailText(b) {
    if (!b || !(b.funded > 0)) return ""
    var text = formatMoney(b.spent, b.currency) + " spent of " + formatMoney(b.funded, b.currency) + " funded"
    if (b.estimated) text += " · estimated"
    return text
  }

  // ---------------------------------------------------------------- summary
  //
  // The hero's line rotates through what the token counts add up to across
  // every agent; each agent's own tables sit in its section below.

  readonly property var summaryPhrases: {
    var rev = usage.dataRevision
    var week = 0
    var today = 0
    var prompts = 0
    var sessions = 0
    var byDay = {}
    var byModel = {}
    for (var i = 0; i < providers.length; i++) {
      var p = providers[i]
      var days = p.recentDays || []
      for (var d = 0; d < days.length; d++) {
        var tokens = Number(days[d].messageCount || 0)
        week += tokens
        byDay[days[d].date] = (byDay[days[d].date] || 0) + tokens
      }
      today += Number(p.todayTotalTokens || 0)
      if (p.hasPromptStats !== false) {
        prompts += Number(p.todayPrompts || 0)
        sessions += Number(p.todaySessions || 0)
      }
      var models = p.modelUsage || {}
      for (var id in models) {
        var bucket = models[id] || {}
        var total = Number(bucket.inputTokens || 0) + Number(bucket.outputTokens || 0)
          + Number(bucket.cacheReadInputTokens || 0) + Number(bucket.cacheCreationInputTokens || 0)
        var name = usage.friendlyModelName(id)
        byModel[name] = (byModel[name] || 0) + total
      }
    }

    var phrases = []
    if (week > 0) phrases.push(usage.formatTokenCount(week) + " tokens this week")
    if (today > 0) phrases.push(usage.formatTokenCount(today) + " tokens today")
    var topModel = ""
    for (var model in byModel) if (topModel === "" || byModel[model] > byModel[topModel]) topModel = model
    if (topModel !== "" && byModel[topModel] > 0) phrases.push("Mostly " + topModel)
    var busiest = ""
    for (var date in byDay) if (busiest === "" || byDay[date] > byDay[busiest]) busiest = date
    if (busiest !== "" && byDay[busiest] > 0) phrases.push("Busiest day: " + weekdayName(busiest))
    if (prompts > 0) phrases.push(prompts + " prompt" + (prompts === 1 ? "" : "s") + " today")
    if (sessions > 0) phrases.push(sessions + " session" + (sessions === 1 ? "" : "s") + " today")
    return phrases
  }
  property int phraseIndex: 0
  // Every record that lands rebuilds the phrases, and a refresh lands each
  // agent's in turn. Indexing the live list would swap the line on each of
  // those, so the hero holds what it shows until the next fade.
  property string shownPhrase: ""
  readonly property string heroPhrase: addStage !== "" || picking
    ? addHeading
    : (shownPhrase !== "" ? shownPhrase : "Subscriptions")

  function showPhrase() {
    var n = summaryPhrases.length
    shownPhrase = n > 0 ? summaryPhrases[phraseIndex % n] : ""
  }

  onSummaryPhrasesChanged: if (shownPhrase === "" || summaryPhrases.length <= 1) showPhrase()

  function weekdayName(date) {
    var parsed = new Date(String(date || "") + "T00:00:00")
    if (isNaN(parsed.getTime())) return String(date || "")
    return ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"][parsed.getDay()]
  }

  // ---------------------------------------------------------------- content

  // Local calendar date, recomputed from nowMs so a panel left open across
  // midnight moves the "Today" row with the clock.
  function todayDate() {
    var now = new Date(root.nowMs)
    return now.getFullYear()
      + "-" + String(now.getMonth() + 1).padStart(2, "0")
      + "-" + String(now.getDate()).padStart(2, "0")
  }

  function dayName(date) {
    var parsed = new Date(String(date || "") + "T00:00:00")
    if (isNaN(parsed.getTime())) return String(date || "")
    return ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"][parsed.getDay()]
  }

  function dayLabel(date, today) {
    if (today) return "Today"
    return dayName(date)
  }

  function dayTooltip(day, today, p) {
    if (!day) return ""
    var parsed = new Date(String(day.date) + "T00:00:00")
    var label = isNaN(parsed.getTime())
      ? String(day.date)
      : dayName(day.date) + " " + (parsed.getMonth() + 1) + "/" + parsed.getDate()
    var text = label + " · " + usage.formatTokenCount(Number(day.messageCount || 0)) + " tokens"
    // Prompt and session counts only exist for today, so they ride along here
    // instead of taking a section of their own. Billing-API agents never
    // count prompts, and "0 prompts" would read as a quiet day, not a gap.
    if (today && p && p.hasPromptStats !== false)
      text += " · " + Number(p.todayPrompts || 0) + " prompts · "
        + Number(p.todaySessions || 0) + " sessions"
    return text
  }

  function weekPeak(p) {
    var days = p ? (p.recentDays || []) : []
    var peak = 0
    for (var i = 0; i < days.length; i++) peak = Math.max(peak, Number(days[i].messageCount || 0))
    return peak
  }

  function modelRows(p) {
    var usageByModel = p ? (p.modelUsage || {}) : {}
    var rows = []
    for (var id in usageByModel) {
      var bucket = usageByModel[id] || {}
      var input = Number(bucket.inputTokens || 0)
      var output = Number(bucket.outputTokens || 0)
      var cacheRead = Number(bucket.cacheReadInputTokens || 0)
      var cacheWrite = Number(bucket.cacheCreationInputTokens || 0)
      rows.push({
        name: usage.friendlyModelName(id),
        total: input + output + cacheRead + cacheWrite,
        input: input,
        output: output,
        cacheRead: cacheRead,
        cacheWrite: cacheWrite
      })
    }
    rows.sort(function(a, b) { return b.total - a.total })
    return rows.slice(0, 4)
  }

  function modelTooltip(row) {
    if (!row) return ""
    return "In " + usage.formatTokenCount(row.input)
      + " · out " + usage.formatTokenCount(row.output)
      + " · cache read " + usage.formatTokenCount(row.cacheRead)
      + " · cache write " + usage.formatTokenCount(row.cacheWrite)
  }

  // Only speaks up when the numbers cover more than this machine.
  function footerText() {
    if (usage.syncStatusText !== "") return usage.syncStatusText
    for (var i = 0; i < providers.length; i++) {
      var count = Number(providers[i].syncDeviceCount || 0)
      if (providers[i].syncEnabled && count > 0)
        return "Merged from " + count + " device" + (count === 1 ? "" : "s")
    }
    return ""
  }

  // Agents that ship a white mark carry an `assets/<id>-light.svg` twin for
  // light surfaces; marks that work on both (Claude's brand-orange) ship one
  // file. The luminance check decides which candidate to try first.
  function colorChannelLuminance(value) {
    var channel = Number(value)
    if (!isFinite(channel)) return 0
    return channel <= 0.03928 ? channel / 12.92 : Math.pow((channel + 0.055) / 1.055, 2.4)
  }

  function colorLuminance(color) {
    return 0.2126 * colorChannelLuminance(color.r)
      + 0.7152 * colorChannelLuminance(color.g)
      + 0.0722 * colorChannelLuminance(color.b)
  }

  // Marks resolve by convention, so a new agent's data file needs nothing
  // from this panel: assets/<id>.svg if it ships one, the module's bar glyph
  // if it doesn't.
  function iconCandidatesForProvider(p, surfaceColor) {
    if (!p) return []
    var candidates = []
    if (colorLuminance(surfaceColor || Commons.Color.background) >= 0.5)
      candidates.push(Qt.resolvedUrl("assets/" + p.providerId + "-light.svg"))
    candidates.push(Qt.resolvedUrl("assets/" + p.providerId + ".svg"))
    return candidates
  }

  // In the bar whenever there's something to do here: usage to report, or,
  // where `omarchy agent account` exists, a first subscription to sign in to.
  // Without either, Bar.qml collapses the slot of an invisible item.
  visible: providers.length > 0 || usage.accountTools
  readonly property bool anySignedIn: {
    for (var id in addChecks)
      if (addChecks[id] !== "first") return true
    return false
  }
  readonly property bool blankSlate: providers.length === 0 && !anySignedIn
  // Choosing a provider: asked for with the +, or simply what the panel is
  // while nothing is set up. It's derived rather than switched into, so
  // records that load a moment after the panel opens take its place.
  readonly property bool picking: addStage === "pick" || (blankSlate && addStage === "" && usage.accountTools)
  // The + in the hero turns into the X that leaves adding. A first setup has
  // nothing to go back to until an agent is chosen.
  readonly property bool addButtonShown: usage.accountTools && (!blankSlate || !picking)

  // Adding takes over the hero's line, and the cursor starts over.
  readonly property string addHeading: picking || addProvider === ""
    ? "Add an account"
    : "Add " + (/^[AEIOU]/.test(addProviderName(addProvider)) ? "an " : "a ") + addProviderName(addProvider) + " account"
  onAddStageChanged: {
    phraseSwap.stop()
    if (hero) hero.metaOpacity = 1.0
    resetKeys()
  }

  // A first setup ends when the records land, which swaps the rows under the
  // cursor without any stage change.
  onPickingChanged: resetKeys()

  // Picking an agent to add starts on the first one, ready for Enter. The
  // rows follow the same stage change, so the cursor waits a tick for them.
  function resetKeys() {
    cursorActive = false
    keyRow = 0
    keyColumn = 0
    Qt.callLater(function() { if (picking) pointAt("choice", 0) })
  }
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onProviderIndexChanged: if (panelFlick) panelFlick.contentY = 0
  onOpenedChanged: if (opened) {
    if (addStage !== "running") addStage = ""
    resetKeys()
    if (providers.length === 0 && usage.accountTools && !checkProcess.running) checkProcess.running = true
    nowMs = Date.now()
    if (panelFlick) panelFlick.contentY = 0
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  readonly property var usage: UsageService
  Component.onCompleted: usage.settings = root.settings
  onSettingsChanged: usage.settings = root.settings

  // Countdown and chart geometry only need a clock while the panel is visible.
  Timer {
    interval: 30000
    running: root.opened
    repeat: true
    onTriggered: root.nowMs = Date.now()
  }

  Process {
    id: checkProcess
    running: false
    command: ["omarchy-agent-account-add", "--check"]
    stdout: SplitParser {
      onRead: function(line) {
        var parts = String(line).trim().split(" ")
        if (parts.length !== 2) return
        var checks = Object.assign({}, root.addChecks)
        checks[parts[0]] = parts[1]
        root.addChecks = checks
      }
    }
  }

  Process {
    id: addProcess
    running: false
    stdinEnabled: true
    stdout: SplitParser { onRead: function(line) { root.handleAddLine(line) } }
    onExited: {
      if (root.addStage === "running") {
        root.addResult = "The sign-in didn't finish."
        root.addStage = "error"
      }
    }
  }

  Timer {
    id: addDoneTimer
    interval: 2500
    onTriggered: if (root.addStage === "done" && !root.blankSlate) root.addStage = ""
  }

  Timer {
    interval: 2800
    running: root.opened && root.summaryPhrases.length > 1 && root.addStage === "" && !root.picking
    repeat: true
    onTriggered: phraseSwap.restart()
  }

  SequentialAnimation {
    id: phraseSwap
    PropertyAnimation {
      target: hero; property: "metaOpacity"
      to: 0.0; duration: root.motion(180); easing.type: Easing.OutQuad
    }
    ScriptAction {
      script: {
        root.phraseIndex = (root.phraseIndex + 1) % Math.max(1, root.summaryPhrases.length)
        root.showPhrase()
      }
    }
    PropertyAnimation {
      target: hero; property: "metaOpacity"
      to: 1.0; duration: root.motion(260); easing.type: Easing.InQuad
    }
  }

  IpcHandler {
    target: root.ipcTarget
    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function refresh(): string { root.refreshNow(); return "ok" }
    function next(): string { root.selectProvider(root.providerIndex + 1); return "ok" }
  }

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    labelVisible: false
    hasVisualContent: true
    active: root.alarming
    tooltipText: root.barTooltip()
    horizontalMargin: 6
    clip: true
    fixedWidth: vertical ? -1 : Style.bar.iconSlot
    onPressed: function(buttonCode) {
      if (buttonCode === Qt.RightButton) root.launchAgent()
      else if (buttonCode === Qt.MiddleButton) root.refreshNow()
      else root.toggle()
    }

    component RemainingMeter: Item {
      id: meter
      property real leftover: root.remainingRatio
      property real radius: 0
      readonly property color usedColor: root.alpha(root.foreground, 0.22)
      readonly property color leftColor: leftover >= 0 && leftover <= 0.1 ? root.urgent : root.foreground

      Rectangle {
        anchors.fill: parent
        radius: meter.radius
        color: usedColor
      }

      Rectangle {
        anchors.left: parent.left
        anchors.top: parent.top
        anchors.bottom: parent.bottom
        width: Math.max(0, parent.width * Math.max(0, leftover))
        radius: meter.radius
        color: leftColor
      }

      Rectangle {
        anchors.left: parent.left
        anchors.top: parent.top
        anchors.bottom: parent.bottom
        width: 1
        radius: meter.radius > 0 ? 1 : 0
        color: leftColor
      }

      Rectangle {
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.bottom: parent.bottom
        width: 1
        radius: meter.radius > 0 ? 1 : 0
        color: leftover >= 1 ? leftColor : root.alpha(root.foreground, 0.55)
      }
    }

    Item {
      visible: root.remainingStyle === "logo-bar" || root.remainingStyle === "logo-on-bar" || root.remainingPct < 0
      anchors.centerIn: parent
      width: Style.bar.iconCanvas
      height: Style.bar.iconCanvas

      Text {
        anchors.centerIn: parent
        text: root.providerGlyph()
        color: root.alarming ? root.urgent : root.foreground
        font.family: root.iconFontFamily
        font.pixelSize: Style.bar.iconCanvas
      }
    }

    RemainingMeter {
      // Crossfade with Bar.qml's openPanelIndicator (120ms OutCubic).
      // A visible: !opened cut leaves a hole while the accent mark fades in.
      visible: opacity > 0
        && (root.remainingStyle === "logo-bar" || root.remainingStyle === "logo-on-bar")
        && root.remainingRatio >= 0
      opacity: root.opened ? 0 : 1
      radius: Math.min(width, height) / 2
      width: root.vertical ? root.remainingMeterThickness : root.remainingMeterLength
      height: root.vertical ? root.remainingMeterLength : root.remainingMeterThickness
      x: root.vertical
        ? (root.barPosition === "left" ? parent.width - width - root.remainingMeterInset : root.remainingMeterInset)
        : Math.round((parent.width - width) / 2)
      y: root.vertical
        ? Math.round((parent.height - height) / 2)
        : (root.barPosition === "top" ? parent.height - height - root.remainingMeterInset : root.remainingMeterInset)

      Behavior on opacity {
        NumberAnimation { duration: root.motion(120); easing.type: Easing.OutCubic }
      }
    }

    Row {
      id: iconRow
      anchors.centerIn: parent
      spacing: Style.space(3)
      visible: root.remainingStyle === "bar-percent" || root.remainingStyle === "percent"

      RemainingMeter {
        visible: root.remainingStyle === "bar-percent" && root.remainingRatio >= 0
        width: Style.space(root.remainingBarWidth)
        height: Style.space(root.remainingBarHeight)
        anchors.verticalCenter: parent.verticalCenter
      }

      Text {
        visible: root.remainingShowPercent && root.remainingPct >= 0
        text: root.remainingPct + "%"
        color: root.alarming ? root.urgent : root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.space(root.remainingFontSize)
        anchors.verticalCenter: parent.verticalCenter
      }
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(380))
    // Grow to the stacked dashboard (three leftover charts) instead of a
    // 900px cap that hid Codex under the fold; screen edge still clips it.
    contentHeight: panel.fittedContentHeight(column.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent

      // Ctrl+Up/Down (or Ctrl+k/j) asks to move the agent the cursor is in.
      // The key catcher of a shell older than agent accounts has no such
      // request, so it's wired up only where it exists.
      Component.onCompleted: {
        if (!("reorderable" in keyCatcher)) return
        keyCatcher.reorderable = Qt.binding(function() { return root.addStage === "" && !root.renaming })
        keyCatcher.reorderRequested.connect(function(dy) { root.reorderProvider(dy) })
      }

      onMoveRequested: function(dx, dy) {
        // Naming and signing in have their own fields; there the arrows scroll.
        if (root.addStage === "" || root.picking) root.moveKey(dx, dy)
        else if (dy !== 0)
          panelFlick.contentY = root.clamp(panelFlick.contentY + dy * Style.space(56), 0,
                                           Math.max(0, panelFlick.contentHeight - panelFlick.height))
      }
      onActivateRequested: root.activateSelection()
      onCloseRequested: {
        if (root.addStage !== "") root.cancelAdd()
        else root.close()
      }
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) {
        if (t === "r" || t === "R") root.refreshNow()
        else if (t === "m" || t === "M") root.toggleSwitchMode()
        else if (root.addStage === "" && t >= "1" && t <= "9" && Number(t) <= root.accountEntries.length) root.pointAt("account", Number(t) - 1)
      }

      Flickable {
        id: panelFlick
        // Reaches a little into the panel's padding on the left, with the
        // content shifted back, so the box around a lit agent mark isn't
        // clipped where it overhangs the content's edge.
        readonly property real overhang: Style.space(8)
        anchors.fill: parent
        anchors.leftMargin: -overhang
        contentWidth: width
        contentHeight: column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar {
          id: panelScroll
          policy: ScrollBar.AsNeeded
        }

        Column {
          id: column
          x: panelFlick.overhang
          // When the panel scrolls, the bar gets its own strip rather than
          // sitting on top of the right-aligned numbers.
          width: panelFlick.width - panelFlick.overhang - (panelFlick.interactive ? panelScroll.width + Style.space(6) : 0)
          spacing: Style.space(12)

          // ---------- Hero: agents · rotating summary · add ----------
          PanelHero {
            id: hero
            width: parent.width
            title: "Agents"
            meta: root.heroPhrase
            foreground: root.foreground
            fontFamily: root.fontFamily

            iconComponent: Component {
              Text {
                textFormat: Text.PlainText
                text: root.agentsGlyph
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.display
              }
            }

            trailingControl: Component {
              Row {
                spacing: Style.space(6)
                visible: root.addButtonShown || root.addStage === ""

                HeroButton {
                  visible: root.addButtonShown
                  hasCursor: root.hasKey("add")
                  onHovered: root.pointAt("add")
                  readonly property bool adding: root.addStage !== ""
                  glyph: adding ? "󰅖" : "󰐕"
                  tooltip: adding ? "Back to the limits" : "Add a subscription"
                  onClicked: adding ? root.cancelAdd() : root.addAccount()
                }

                HeroButton {
                  visible: root.addStage === ""
                  hasCursor: root.hasKey("launch")
                  onHovered: root.pointAt("launch")
                  glyph: "󰞷"
                  tooltip: "Start the default agent"
                  onClicked: root.launchAgent()
                }
              }
            }
          }

          AddView {
            visible: root.addStage !== "" || root.picking
            width: column.width
          }

          // Where a first subscription can't be signed in to from here, the
          // empty page at least says why it is empty.
          Text {
            visible: root.stackedProviders.length === 0 && !usage.accountTools
            width: parent.width
            topPadding: Style.space(24)
            text: "No AI coding subscriptions found.\nAgents show up here once you've used them."
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.WordWrap
          }

          Item {
            visible: root.addStage === "" && root.stackedProviders.length > 0
            width: parent.width
            implicitHeight: Math.max(axisLabel.implicitHeight, axisControls.implicitHeight)

            Text {
              id: axisLabel
              text: "Chart range"
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
            }

            Row {
              id: axisControls
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter

              ButtonGroup {
                id: axisGroup
                foreground: root.foreground
                fontFamily: root.fontFamily
                fontSize: Style.font.caption
                focusable: false
                value: root.remainingAxis
                options: [
                  { value: "days", label: "2 days" },
                  { value: "cycle", label: "Cycle" }
                ]
                onChanged: function(v) { root.setRemainingAxis(v) }
              }
            }
          }

          Repeater {
            id: providerSections
            model: root.addStage === "" ? root.stackedProviders : []

            ProviderBlock {
              required property var modelData
              required property int index
              width: column.width
              provider: modelData
              providerIndex: index
              showChartHeader: index === root.firstChartProviderIndex
            }
          }

          Item {
            visible: root.addStage === "" && root.stackedProviders.length > 0
            width: parent.width
            implicitHeight: refreshBtn.implicitHeight + Style.space(4)

            Button {
              id: refreshBtn
              anchors.horizontalCenter: parent.horizontalCenter
              anchors.bottom: parent.bottom
              text: root.refreshing ? "Refreshing…" : "Refresh"
              foreground: root.refreshOnCooldown && !root.refreshing ? root.dim : root.foreground
              fontFamily: root.fontFamily
              fontSize: Style.font.caption
              horizontalPadding: 0
              verticalPadding: 0
              enabled: !root.refreshing && !root.refreshOnCooldown
              opacity: root.refreshOnCooldown && !root.refreshing ? 0.55 : 1
              onClicked: root.refreshFromButton()
            }
          }

          // ---------- Make something ----------
          PanelSeparator {
            visible: starters.visible
            foreground: root.foreground
          }

          Column {
            id: starters
            visible: root.addStage === "" && !root.blankSlate
            width: parent.width
            spacing: Style.space(12)

            PanelSectionHeader {
              text: "MAKE SOMETHING COOL"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Row {
              id: tileRow
              width: parent.width
              spacing: Style.space(10)

              Repeater {
                model: root.starterPrompts

                StarterTile {
                  required property var modelData
                  required property int index
                  hasCursor: root.hasKey("starter", index)
                  onHovered: root.pointAt("starter", index)
                  width: (tileRow.width - tileRow.spacing * 2) / 3
                  glyph: modelData.glyph
                  title: modelData.label
                  onClicked: root.startPrompt(modelData.prompt)
                }
              }
            }
          }

          Text {
            textFormat: Text.PlainText
            visible: text !== ""
            width: parent.width
            topPadding: Style.space(2)
            text: root.footerText()
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            horizontalAlignment: Text.AlignHCenter
            elide: Text.ElideRight
          }
        }
      }
    }
  }

  // One provider: its mark, name, and plan, then its limits — or, with
  // several accounts, each account's name, state, and limits in turn — and a
  // prepaid balance when it has one. Below those, this plugin's own rows: the
  // remaining chart and the token tables.
  component ProviderBlock: Column {
    id: block
    property var provider: null
    property int providerIndex: -1
    property bool showChartHeader: false

    readonly property var accounts: root.providerAccounts(block.provider)
    readonly property bool multi: accounts.length > 1
    readonly property var windows: root.limitWindows(block.provider)
    readonly property var models: root.modelRows(block.provider)
    readonly property var balance: block.provider ? (block.provider.balance || null) : null
    readonly property string notice: block.multi ? "" : root.providerNotice(block.provider)
    spacing: Style.space(10)
    opacity: root.dragProviderId !== "" && block.provider && root.dragProviderId === block.provider.providerId ? 0.5 : 1.0

    PanelSeparator {
      width: parent.width
      foreground: root.foreground
    }

    Item {
      id: sectionHead
      width: parent.width
      implicitHeight: Math.max(sectionMark.height, sectionName.implicitHeight)
      // Lit for the keyboard, and as the drop spot while an agent is dragged.
      readonly property bool lit: root.dragProviderId !== "" ? root.dragTarget === block.providerIndex : root.hasKey("provider", block.providerIndex)
      onLitChanged: if (lit && root.dragProviderId === "") root.revealBlock(block)

      // Only the mark is lit: it's the handle the agent moves by.
      CursorSurface {
        anchors.fill: sectionMark
        anchors.margins: -Style.space(5)
        z: -1
        hasCursor: sectionHead.lit
        foreground: root.foreground
      }

      ProviderMark {
        id: sectionMark
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
        provider: block.provider

        // The mark is the handle for dragging the agent up or down the page.
        MouseArea {
          anchors.fill: parent
          anchors.margins: -Style.space(4)
          hoverEnabled: true
          preventStealing: true
          cursorShape: pressed ? Qt.ClosedHandCursor : Qt.OpenHandCursor
          onPressed: {
            root.dragProviderId = block.provider ? block.provider.providerId : ""
            root.dragTarget = block.providerIndex
          }
          onPositionChanged: function(mouse) {
            if (pressed) root.dragProviderOver(mapToItem(column, mouse.x, mouse.y).y)
          }
          onReleased: root.dropProvider()
          onCanceled: { root.dragProviderId = ""; root.dragTarget = -1 }
        }
      }

      Text {
        id: sectionName
        anchors.left: sectionMark.right
        anchors.leftMargin: Style.space(10)
        anchors.right: sectionPlan.left
        anchors.rightMargin: Style.spacing.sm
        anchors.verticalCenter: parent.verticalCenter
        textFormat: Text.PlainText
        text: block.provider ? String(block.provider.providerName || "") : ""
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        font.bold: true
        elide: Text.ElideRight
      }

      Text {
        id: sectionPlan
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        visible: !block.multi
        textFormat: Text.PlainText
        text: root.planLabel(block.provider)
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
      }
    }

    // Sign-in and endpoint trouble for a single-account provider; with
    // several, each account says so on its own line.
    TextLink {
      visible: root.signInOffered(block.provider)
      picked: root.hasKey("providerSignin", block.providerIndex)
      text: "Sign-in required"
      idleColor: root.urgent
      tooltip: "Sign in to " + (block.provider ? block.provider.providerName : "") + " again"
      onClicked: root.signInAgain(block.provider, null)
    }

    Text {
      visible: block.notice !== ""
      width: parent.width
      textFormat: Text.PlainText
      text: block.notice
      color: root.otherTrouble(block.provider) !== "" ? root.urgent : root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      wrapMode: Text.WordWrap
    }

    UnavailableUsage {
      visible: !block.multi && root.pausedWithoutLimits(block.provider)
      width: parent.width
      record: block.provider
    }

    Repeater {
      model: block.multi ? [] : block.windows
      LimitRow {
        required property var modelData
        width: block.width
        window: modelData
        stale: !!block.provider && block.provider.limitsStale === true
        fetchedAt: block.provider ? Number(block.provider.limitsFetchedAt || 0) : 0
      }
    }

    Text {
      textFormat: Text.PlainText
      visible: !block.multi && text !== ""
      width: parent.width
      text: root.resetCreditsText(block.provider ? block.provider.resetCredits : null)
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
    }

    // The meter shows what is left, like every meter here: a prepaid account
    // drains toward empty.
    Column {
      visible: !!block.balance
      width: parent.width
      spacing: Style.space(6)

      Item {
        width: parent.width
        implicitHeight: Math.max(balanceTitle.implicitHeight, balanceValue.implicitHeight)

        Text {
          id: balanceTitle
          text: "Balance"
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          anchors.left: parent.left
          anchors.verticalCenter: parent.verticalCenter
        }

        Text {
          id: balanceValue
          textFormat: Text.PlainText
          text: block.balance ? root.formatMoney(block.balance.remaining, block.balance.currency) + " left" : ""
          color: root.balanceLow(block.balance) ? root.urgent : root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
        }
      }

      Meter {
        visible: !!block.balance && block.balance.funded > 0
        width: parent.width
        value: block.balance && block.balance.funded > 0 ? block.balance.remaining / block.balance.funded : -1
        alarming: root.balanceLow(block.balance)
      }

      Text {
        textFormat: Text.PlainText
        visible: text !== ""
        width: parent.width
        text: root.balanceDetailText(block.balance)
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
      }
    }

    Repeater {
      model: block.multi ? block.accounts : []

      Column {
        id: accountBlock
        required property var modelData
        required property int index
        width: block.width
        topPadding: index > 0 ? Style.space(6) : 0
        spacing: Style.space(10)

        AccountHeader {
          width: parent.width
          account: accountBlock.modelData
          owner: block.provider
          picked: root.isPicked(block.provider, accountBlock.modelData)
        }

        UnavailableUsage {
          width: parent.width
          record: accountBlock.modelData
        }

        Repeater {
          model: root.limitWindows({ limits: accountBlock.modelData.limits || [] })

          LimitRow {
            required property var modelData
            width: accountBlock.width
            window: modelData
            stale: accountBlock.modelData.stale === true
            fetchedAt: Number(accountBlock.modelData.fetchedAt || 0)
          }
        }
      }
    }

    RemainingChart {
      visible: {
        var id = block.provider ? String(block.provider.providerId || "") : ""
        if (id !== "grok" && id !== "grokbot" && id !== "cursor" && id !== "codex" && id !== "antigravity") return false
        var series = root.remainingSeriesFor(block.provider)
        return !!(series && series.length > 0)
      }
      width: parent.width
      series: root.remainingSeriesFor(block.provider)
      showHeader: block.showChartHeader
    }

    PanelSeparator {
      visible: usageSection.visible
      width: parent.width
      foreground: root.foreground
    }

    Column {
      id: usageSection
      readonly property var days: block.provider ? (block.provider.recentDays || []) : []
      readonly property real peak: Math.max(1, root.weekPeak(block.provider))
      readonly property bool open: root.tokenSectionOpen(block.provider, "days")
      visible: days.length > 0
      width: parent.width
      spacing: Style.spacing.md

      FoldHeader {
        width: parent.width
        text: "TOKENS BY DAY"
        summary: root.dayTokensSummary(block.provider)
        open: usageSection.open
        hasCursor: root.hasKey("days", block.providerIndex)
        onHovered: root.pointAt("days", block.providerIndex)
        onClicked: root.toggleTokenSection(block.provider, "days")
      }

      Repeater {
        model: usageSection.open ? usageSection.days : []
        DayRow {
          required property var modelData
          width: usageSection.width
          provider: block.provider
          day: modelData
          ratio: Number(modelData.messageCount || 0) / usageSection.peak
          today: String(modelData.date || "") === root.todayDate()
        }
      }
    }

    PanelSeparator {
      visible: modelSection.visible
      width: parent.width
      foreground: root.foreground
    }

    Column {
      id: modelSection
      readonly property bool open: root.tokenSectionOpen(block.provider, "models")
      visible: block.models.length > 0
      width: parent.width
      spacing: Style.spacing.md

      FoldHeader {
        width: parent.width
        text: "TOKENS BY MODEL"
        summary: root.modelTokensSummary(block.provider)
        open: modelSection.open
        hasCursor: root.hasKey("models", block.providerIndex)
        onHovered: root.pointAt("models", block.providerIndex)
        onClicked: root.toggleTokenSection(block.provider, "models")
      }

      Repeater {
        model: modelSection.open ? block.models : []
        ModelRow {
          required property var modelData
          width: modelSection.width
          row: modelData
          share: modelData.total / Math.max(1, block.models[0].total)
        }
      }
    }
  }

  // Countdown meter: leftover fill. Monthly Cursor pools and Grok weekly
  // both use the even-burn tick when the window has a start/end.
  component LimitRow: Column {
    id: limitRow
    property var window: null
    // Numbers kept from an earlier check after a failed one are dimmed, and
    // say how old they are on hover.
    property bool stale: false
    property real fetchedAt: 0

    readonly property bool alarming: window && window.percent >= 0.9
    readonly property real leftover: window && window.percent >= 0 ? (1 - window.percent) : -1

    spacing: Style.space(6)

    HoverHandler { id: limitHover }

    PanelToolTip {
      visible: limitHover.hovered && limitRow.stale
      text: limitRow.fetchedAt > 0 && root.nowMs - limitRow.fetchedAt > 60000
        ? "Last updated " + root.formatDuration(root.nowMs - limitRow.fetchedAt) + " ago"
        : limitRow.fetchedAt > 0 ? "Last updated less than a minute ago" : "Last updated time unavailable"
      fontFamily: root.fontFamily
    }

    Item {
      width: parent.width
      implicitHeight: Math.max(limitLabel.implicitHeight, limitValue.implicitHeight)

      Text {
        id: limitLabel
        // A model-scoped window is titled after its model, and those names run
        // long enough to reach the percentage, so the title gives way first.
        textFormat: Text.PlainText
        text: limitRow.window ? limitRow.window.title : ""
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        elide: Text.ElideRight
        anchors.left: parent.left
        anchors.right: limitValue.left
        anchors.rightMargin: Style.spacing.sm
        anchors.verticalCenter: parent.verticalCenter
      }

      Text {
        id: limitValue
        text: limitRow.leftover >= 0
          ? Math.round(limitRow.leftover * 100) + "% left"
          : "—"
        color: limitRow.alarming ? root.urgent : (limitRow.stale ? root.dim : root.foreground)
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
      }
    }

    Meter {
      width: parent.width
      value: limitRow.leftover
      alarming: limitRow.alarming
      paceMark: root.paceRemaining(limitRow.window)
    }

    Item {
      id: statusLine
      width: parent.width
      implicitHeight: Math.max(resetText.implicitHeight, paceText.implicitHeight, 1)
      visible: resetPart !== "" || pacePart !== ""

      readonly property string resetPart: {
        var remainingMs = root.resetMsFor(limitRow.window)
        return remainingMs > 0 ? "Resets in " + root.formatDuration(remainingMs) : ""
      }
      readonly property string pacePart: root.paceCaption(limitRow.window)

      Text {
        id: paceText
        visible: statusLine.pacePart !== ""
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        text: statusLine.pacePart
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        horizontalAlignment: Text.AlignRight
        elide: Text.ElideLeft
        maximumLineCount: 1
      }

      Text {
        id: resetText
        visible: statusLine.resetPart !== ""
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
        anchors.right: paceText.visible ? paceText.left : parent.right
        anchors.rightMargin: paceText.visible ? Style.space(8) : 0
        text: statusLine.resetPart
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
        horizontalAlignment: Text.AlignLeft
        elide: Text.ElideRight
        maximumLineCount: 1
      }
    }
  }

  // Countdown track: fill is leftover, not spent. A weekly pace tick marks
  // the even-burn remaining (CodexBar). Square so the slot stays readable.
  component Meter: Item {
    id: meter
    property real value: -1
    property bool alarming: false
    property real paceMark: -1
    property real thickness: Math.max(Style.space(6), Math.round(Style.spacing.controlHeight * 0.18))

    implicitHeight: thickness

    Rectangle {
      id: meterTrack
      anchors.fill: parent
      radius: 0
      color: root.alpha(root.foreground, 0.22)
    }

    Rectangle {
      anchors.left: meterTrack.left
      anchors.top: meterTrack.top
      anchors.bottom: meterTrack.bottom
      radius: 0
      width: Math.max(0, meterTrack.width * root.clamp(meter.value, 0, 1))
      color: meter.alarming ? root.urgent : root.foreground

      Behavior on width {
        NumberAnimation { duration: root.motion(160); easing.type: Easing.OutCubic }
      }
    }

    Rectangle {
      anchors.left: meterTrack.left
      anchors.top: meterTrack.top
      anchors.bottom: meterTrack.bottom
      width: 1
      color: meter.alarming ? root.urgent : root.foreground
    }

    Rectangle {
      anchors.right: meterTrack.right
      anchors.top: meterTrack.top
      anchors.bottom: meterTrack.bottom
      width: 1
      color: meter.value >= 1
        ? (meter.alarming ? root.urgent : root.foreground)
        : root.alpha(root.foreground, 0.55)
    }

    Rectangle {
      visible: meter.paceMark >= 0
      width: 2
      height: meterTrack.height + 4
      y: -2
      x: 1 + Math.max(0, meterTrack.width - 2) * root.clamp(meter.paceMark, 0, 1) - 1
      color: root.urgent
    }
  }

  // Adding a subscription, in place of the list: pick, name, sign in.
  component AddView: Column {
    id: add
    spacing: Style.space(14)

    PanelSeparator { foreground: root.foreground }

    Text {
      visible: root.blankSlate && root.picking
      width: parent.width
      text: "Sign in to an AI coding subscription, and this panel keeps track of how much of it you have left."
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      wrapMode: Text.WordWrap
    }

    // Pick: each agent by a large mark over its name, three across.
    Row {
      id: choiceRow
      visible: root.picking
      width: parent.width
      spacing: Style.space(10)

      Repeater {
        model: root.picking ? root.addProviders : []

        Item {
          id: choice
          required property var modelData
          required property int index
          readonly property string state: root.addChecks[modelData.providerId] || ""
          readonly property bool available: state === "first" || state === "additional"
          readonly property bool hasCursor: root.hasKey("choice", index)
          width: (choiceRow.width - choiceRow.spacing * (root.addProviders.length - 1)) / root.addProviders.length
          implicitHeight: choiceBody.implicitHeight + Style.space(16)
          onHasCursorChanged: if (hasCursor) root.revealItem(choice)

          Column {
            id: choiceBody
            anchors.centerIn: parent
            spacing: Style.space(10)

            ProviderMark {
              anchors.horizontalCenter: parent.horizontalCenter
              provider: choice.modelData
              size: Style.font.display * 1.6
              scale: choice.hasCursor ? 1.08 : 1.0
              Behavior on scale { NumberAnimation { duration: root.motion(120); easing.type: Easing.OutQuad } }
            }

            Text {
              anchors.horizontalCenter: parent.horizontalCenter
              textFormat: Text.PlainText
              text: choice.modelData.providerName
              color: choice.hasCursor ? Commons.Color.accent : root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              font.bold: true
            }
          }

          MouseArea {
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: choice.available ? Qt.PointingHandCursor : Qt.ArrowCursor
            onEntered: root.pointAt("choice", choice.index)
            onClicked: root.chooseAddProvider(choice.modelData.providerId)
          }

        }
      }
    }

    // Name: a second account needs telling apart from the first.
    Column {
      visible: root.addStage === "name"
      width: parent.width
      spacing: Style.space(10)

      Text {
        width: parent.width
        text: "Name this account. It signs in through a private window, so your browser's current account isn't picked up."
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        wrapMode: Text.WordWrap
      }

      TextField {
        id: addNameField
        width: parent.width
        placeholderText: "Work"
        foreground: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        onVisibleChanged: if (visible) { text = ""; forceActiveFocus() }
        onAccepted: root.startAdd(text.trim())
        Keys.onEscapePressed: function(event) { root.cancelAdd(); event.accepted = true }
      }
    }

    // Running: what's happening, and whatever the sign-in needs from you.
    Column {
      visible: root.addStage === "running"
      width: parent.width
      spacing: Style.space(12)

      Text {
        width: parent.width
        textFormat: Text.PlainText
        text: root.addStatus
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
        wrapMode: Text.WordWrap
      }

      Column {
        visible: root.addCode !== ""
        width: parent.width
        spacing: Style.space(4)

        Text {
          text: "Confirm this code in your browser"
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }

        Text {
          textFormat: Text.PlainText
          text: root.addCode
          color: Commons.Color.accent
          font.family: root.fontFamily
          font.pixelSize: Style.font.display
          font.bold: true
          font.letterSpacing: 2
        }
      }

      Column {
        visible: root.addNeedsPaste
        width: parent.width
        spacing: Style.space(6)

        Text {
          width: parent.width
          text: "If the page shows a code instead of finishing, paste it here."
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          wrapMode: Text.WordWrap
        }

        TextField {
          id: pasteField
          width: parent.width
          placeholderText: "Code"
          foreground: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          onAccepted: { root.submitPaste(text); text = "" }
          Keys.onEscapePressed: function(event) { root.cancelAdd(); event.accepted = true }
        }
      }

      TextLink {
        visible: root.addUrl !== ""
        text: "Open the sign-in page again"
        onClicked: root.reopenSignIn()
      }
    }

    // Done or failed.
    Text {
      visible: root.addStage === "done" || root.addStage === "error"
      width: parent.width
      textFormat: Text.PlainText
      text: root.addResult
      color: root.addStage === "error" ? root.urgent : root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
      wrapMode: Text.WordWrap
    }
  }

  // A provider's mark in the theme's ink: Grok and Codex come from the
  // omarchy icon font, the rest are their light-on-transparent SVG, recolored.
  // One that ships no mark falls back to the bar glyph.
  component ProviderMark: Item {
    id: mark
    property var provider: null
    property real size: Style.font.heading
    readonly property string pid: provider ? String(provider.providerId || "") : ""
    readonly property bool fontMark: pid === "grok" || pid === "codex"

    width: size
    height: size

    Text {
      visible: mark.fontMark
      anchors.centerIn: parent
      text: mark.pid === "grok" ? "" : ""
      color: root.foreground
      font.family: root.iconFontFamily
      font.pixelSize: mark.size
    }

    // Always sample the light-on-transparent mark. The -light twin is
    // near-black and colorization cannot lift it to the theme ink.
    Image {
      id: markImage
      visible: false
      layer.enabled: !mark.fontMark
      anchors.fill: parent
      source: mark.fontMark || mark.pid === "" ? "" : Qt.resolvedUrl("assets/" + mark.pid + ".svg")
      sourceSize.width: mark.size * 2
      sourceSize.height: mark.size * 2
      fillMode: Image.PreserveAspectFit
    }

    MultiEffect {
      visible: !mark.fontMark && markImage.status === Image.Ready
      anchors.fill: markImage
      source: markImage
      colorization: 1.0
      colorizationColor: root.foreground
    }

    Text {
      visible: !mark.fontMark && markImage.status !== Image.Ready
      anchors.centerIn: parent
      textFormat: Text.PlainText
      text: root.agentsGlyph
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: mark.size
    }
  }

  // A starter: its glyph and what it makes, on a soft tile that warms to the
  // accent on hover.
  component StarterTile: Rectangle {
    id: tile
    signal clicked()
    signal hovered()
    property string glyph: ""
    property string title: ""
    property bool hasCursor: false
    implicitHeight: tileBody.implicitHeight + Style.space(20)
    radius: Style.cornerRadius
    color: hasCursor ? root.alpha(Commons.Color.accent, 0.14) : root.alpha(root.foreground, 0.05)
    onHasCursorChanged: if (hasCursor) root.revealItem(tile)

    Row {
      id: tileBody
      anchors.centerIn: parent
      spacing: Style.space(8)

      Text {
        anchors.verticalCenter: parent.verticalCenter
        textFormat: Text.PlainText
        text: tile.glyph
        color: Commons.Color.accent
        font.family: root.fontFamily
        font.pixelSize: Style.font.heading
      }

      Text {
        anchors.verticalCenter: parent.verticalCenter
        textFormat: Text.PlainText
        text: tile.title
        color: tile.hasCursor ? Commons.Color.accent : root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        font.bold: true
      }
    }

    MouseArea {
      id: tileMouse
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onEntered: tile.hovered()
      onClicked: tile.clicked()
    }

    PanelToolTip {
      visible: tileMouse.containsMouse
      text: "Start your default agent on a new " + tile.title.toLowerCase()
    }
  }

  // The tinted square in the hero's corner: start an agent, add a subscription.
  component HeroButton: Rectangle {
    id: heroButton
    signal clicked()
    signal hovered()
    property string glyph: ""
    property string tooltip: ""
    property bool hasCursor: false
    implicitWidth: Style.space(34)
    implicitHeight: implicitWidth
    radius: Style.cornerRadius
    // The cursor needs more than a shade deeper to read on a tinted square.
    color: root.alpha(Commons.Color.accent, hasCursor ? 0.3 : 0.12)
    border.width: hasCursor ? Math.max(1, Style.hoverBorderWidth) : 0
    border.color: Commons.Color.accent
    onHasCursorChanged: if (hasCursor) root.revealItem(heroButton)

    Text {
      anchors.centerIn: parent
      textFormat: Text.PlainText
      text: heroButton.glyph
      color: Commons.Color.accent
      font.family: root.fontFamily
      font.pixelSize: Style.font.heading
    }

    MouseArea {
      id: heroMouse
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onEntered: heroButton.hovered()
      onClicked: heroButton.clicked()
    }

    PanelToolTip {
      visible: heroMouse.containsMouse
      text: heroButton.tooltip
    }
  }

  // A plain-text control: dim until hovered or picked, accent when it's the
  // current choice. Stands in for bordered buttons, which pile up here.
  component TextLink: Text {
    id: link
    signal clicked()
    property bool current: false
    property bool picked: false
    property string tooltip: ""
    property color idleColor: root.dim
    readonly property bool hot: linkMouse.containsMouse || picked
    onPickedChanged: if (picked) root.revealItem(link)
    textFormat: Text.PlainText
    color: current ? Commons.Color.accent : (hot ? root.foreground : idleColor)
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
    font.bold: current
    font.underline: hot && !current

    MouseArea {
      id: linkMouse
      anchors.fill: parent
      anchors.margins: -Style.space(4)
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: link.clicked()
    }

    PanelToolTip {
      visible: link.tooltip !== "" && linkMouse.containsMouse
      text: link.tooltip
    }
  }

  // An account's name, email and plan, with ACTIVE or a Use link on the
  // right. Clicking the name edits it in place: Enter renames, Esc or
  // clicking away leaves it as it was.
  component AccountHeader: Item {
    id: head
    property var account: ({})
    property var owner: null
    property bool picked: false
    property bool editing: false
    // The new name shows at once; the record catches up a moment later.
    property string renamedTo: ""
    readonly property bool isActive: account.active === true
    readonly property bool autoOn: root.autoSwitchFor(owner)
    // Which of the row's links the keyboard is on, when it's on this row.
    readonly property string pickedKind: picked && root.keyTarget ? root.keyTarget.kind : ""
    readonly property string label: renamedTo !== "" ? renamedTo : String(account.label || account.id || "")

    onAccountChanged: renamedTo = ""
    onEditingChanged: root.renaming = editing
    onPickedChanged: if (picked) root.revealItem(head)

    // Anywhere on the line counts, so Use can show up when it's hidden.
    HoverHandler { id: useHover }
    implicitHeight: Math.max(headText.implicitHeight, headAction.implicitHeight)

    function startRename() {
      editing = true
      nameField.text = label
      nameField.forceActiveFocus()
      nameField.selectAll()
    }

    function finishRename(save) {
      if (!editing) return
      var value = nameField.text.trim()
      editing = false
      root.focusKeys()
      if (save && value !== "" && value !== label) {
        renamedTo = value
        root.renameAccount(owner, account, value)
      }
    }

    // One line: the name, then its plan and any caveats, quieter. The
    // email is the name's tooltip.
    Item {
      id: headText
      anchors.left: parent.left
      anchors.right: headAction.left
      anchors.rightMargin: Style.spacing.sm
      implicitHeight: head.editing ? nameField.implicitHeight : nameText.implicitHeight

      Text {
        id: nameText
        textFormat: Text.PlainText
        visible: !head.editing
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
        width: Math.min(implicitWidth, parent.width * 0.6)
        text: head.label
        color: head.picked ? Commons.Color.accent : root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        font.bold: head.isActive
        font.underline: nameMouse.containsMouse
        elide: Text.ElideRight

        MouseArea {
          id: nameMouse
          anchors.fill: parent
          hoverEnabled: true
          cursorShape: Qt.IBeamCursor
          onClicked: head.startRename()
        }

        PanelToolTip {
          visible: nameMouse.containsMouse && String(head.account.email || "") !== ""
          text: String(head.account.email || "")
        }
      }

      // Bounded by the actions on the right: the plan and any trouble shorten
      // first, and the Sign-in required link keeps its whole width.
      Row {
        id: detailRow
        visible: !head.editing
        anchors.left: nameText.right
        anchors.leftMargin: Style.space(8)
        anchors.verticalCenter: nameText.verticalCenter
        width: Math.max(0, parent.width - nameText.width - Style.space(8))
        spacing: Style.space(8)

        Text {
          textFormat: Text.PlainText
          visible: text !== ""
          width: Math.max(0, Math.min(implicitWidth, detailRow.width
            - (signInDot.visible ? signInDot.implicitWidth + detailRow.spacing : 0)
            - (signInLink.visible ? signInLink.implicitWidth + detailRow.spacing : 0)))
          elide: Text.ElideRight
          text: {
            var parts = []
            var detail = root.accountDetail(head.account)
            if (detail !== "") parts.push(detail)
            var trouble = root.otherTrouble(head.account)
            if (trouble !== "") parts.push(trouble)
            return parts.length > 0 ? "· " + parts.join(" · ") : ""
          }
          color: root.otherTrouble(head.account) !== "" ? root.urgent : root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }

        // The dot is punctuation, not part of the link.
        Text {
          id: signInDot
          visible: root.needsSignIn(head.account)
          text: "·"
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }

        TextLink {
          id: signInLink
          visible: root.needsSignIn(head.account)
          picked: head.pickedKind === "signin"
          text: "Sign-in required"
          idleColor: root.urgent
          tooltip: "Sign in to this account again"
          onClicked: root.signInAgain(head.owner, head.account)
        }
      }

      TextField {
        id: nameField
        visible: head.editing
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        foreground: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        horizontalPadding: Style.space(4)
        verticalPadding: Style.space(1)
        onAccepted: head.finishRename(true)
        onActiveFocusChanged: if (!activeFocus) head.finishRename(false)
        Keys.onEscapePressed: function(event) {
          head.finishRename(false)
          event.accepted = true
        }
      }
    }

    Item {
      id: headAction
      anchors.right: parent.right
      anchors.top: parent.top
      implicitWidth: head.isActive ? headActive.implicitWidth : useRow.implicitWidth
      implicitHeight: head.isActive ? headActive.implicitHeight : useRow.implicitHeight

      Text {
        id: headActive
        visible: head.isActive
        anchors.right: parent.right
        text: "ACTIVE"
        color: Commons.Color.accent
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        font.bold: true
      }

      // Switching now is Use. Hovering it also offers Autoswitch: move new
      // sessions over by themselves once the active account reaches the
      // threshold. While that's on it stays in view in place of Use, and
      // clicking it again goes back to only being notified.
      Row {
        id: useRow
        visible: !head.isActive
        anchors.right: parent.right
        spacing: Style.space(12)

        TextLink {
          visible: head.autoOn || useHover.hovered || head.picked
          text: head.pickedKind === "autoswitch" ? "Autoswitch ⏎" : "Autoswitch"
          picked: head.pickedKind === "autoswitch"
          current: head.autoOn
          tooltip: head.autoOn
            ? "Stop switching automatically"
            : "Switch here automatically at " + root.switchThreshold(head.owner) + "%"
          onClicked: root.setSwitchMode(head.owner, head.autoOn ? "manual" : "auto")
        }

        // With Autoswitch on, Use waits until the line is hovered or picked.
        TextLink {
          visible: !head.autoOn || useHover.hovered || head.picked
          text: head.pickedKind === "account" ? "Use ⏎" : "Use"
          picked: head.pickedKind === "account"
          onClicked: root.useAccount(head.owner, head.account)
        }
      }
    }
  }

  // With no measured windows, leave a place to discover how to get usage.
  component UnavailableUsage: Item {
    id: unavailable
    property var record: null
    visible: root.pausedWithoutLimits(record)
    implicitHeight: unavailableLabel.implicitHeight

    Text {
      id: unavailableLabel
      text: "Usage unavailable"
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
    }

    HoverHandler { id: unavailableHover }

    PanelToolTip {
      visible: unavailableHover.hovered && unavailable.visible
      text: unavailable.record ? String(unavailable.record.authHelpText || "Usage has not been updated yet.") : ""
    }
  }

  // A token table's header, which folds the table open and shut. Closed, it
  // carries a one-line summary of what's behind it.
  component FoldHeader: Item {
    id: fold
    signal clicked()
    signal hovered()
    property string text: ""
    property string summary: ""
    property bool open: false
    property bool hasCursor: false
    implicitHeight: Math.max(foldLabel.implicitHeight, foldSummary.implicitHeight)
    onHasCursorChanged: if (hasCursor) root.revealItem(fold)

    CursorSurface {
      anchors.fill: parent
      anchors.margins: -Style.space(4)
      hasCursor: fold.hasCursor
      foreground: root.foreground
    }

    Text {
      id: foldChevron
      anchors.left: parent.left
      anchors.verticalCenter: foldLabel.verticalCenter
      width: Style.space(14)
      text: fold.open ? "▾" : "▸"
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
    }

    PanelSectionHeader {
      id: foldLabel
      anchors.left: foldChevron.right
      anchors.verticalCenter: parent.verticalCenter
      text: fold.text
      foreground: root.foreground
      fontFamily: root.fontFamily
    }

    Text {
      id: foldSummary
      visible: text !== ""
      anchors.left: foldLabel.right
      anchors.leftMargin: Style.space(10)
      anchors.right: parent.right
      anchors.verticalCenter: foldLabel.verticalCenter
      horizontalAlignment: Text.AlignRight
      textFormat: Text.PlainText
      text: fold.open ? "" : fold.summary
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      elide: Text.ElideRight
    }

    MouseArea {
      anchors.fill: parent
      anchors.margins: -Style.space(4)
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onEntered: fold.hovered()
      onClicked: fold.clicked()
    }
  }

  // One row per day: label, bar, tokens. Today is picked out in full
  // foreground so the week reads as a run-up to right now.
  component DayRow: Item {
    id: dayRow
    property var provider: null
    property var day: null
    property real ratio: 0
    property bool today: false

    implicitHeight: Math.max(dayLabel.implicitHeight, dayValue.implicitHeight) + Style.spacing.sm

    Text {
      id: dayLabel
      textFormat: Text.PlainText
      text: root.dayLabel(dayRow.day ? dayRow.day.date : "", dayRow.today)
      color: dayRow.today ? root.foreground : root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      font.bold: dayRow.today
      anchors.left: parent.left
      anchors.verticalCenter: parent.verticalCenter
      width: Style.space(52)
    }

    Rectangle {
      id: dayTrack
      anchors.left: dayLabel.right
      anchors.right: dayValue.left
      anchors.leftMargin: Style.space(8)
      anchors.rightMargin: Style.space(10)
      anchors.verticalCenter: parent.verticalCenter
      height: Math.max(Style.space(4), Math.round(Style.spacing.controlHeight * 0.14))
      radius: height / 2
      color: root.track

      Rectangle {
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
        height: parent.height
        radius: parent.radius
        width: parent.width * root.clamp(dayRow.ratio, 0, 1)
        color: dayRow.today ? root.foreground : root.alpha(root.foreground, 0.55)

        Behavior on width {
          NumberAnimation { duration: root.motion(160); easing.type: Easing.OutCubic }
        }
      }
    }

    Text {
      id: dayValue
      text: usage.formatTokenCount(dayRow.day ? Number(dayRow.day.messageCount || 0) : 0)
      color: dayRow.today ? root.foreground : root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      font.bold: true
      horizontalAlignment: Text.AlignRight
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      width: Style.space(52)
    }

    MouseArea {
      id: dayHover
      anchors.fill: parent
      hoverEnabled: true
      acceptedButtons: Qt.NoButton
    }

    PanelToolTip {
      visible: dayHover.containsMouse
      text: root.dayTooltip(dayRow.day, dayRow.today, dayRow.provider)
      fontFamily: root.fontFamily
    }
  }

  // Model rows read as a table: the share bar fills the row behind the label
  // instead of stacking under it, which keeps the whole dashboard on one screen.
  component ModelRow: Item {
    id: modelRow
    property var row: null
    property real share: 0

    implicitHeight: modelName.implicitHeight + Style.spacing.lg

    Rectangle {
      anchors.fill: parent
      radius: Style.cornerRadius
      color: root.alpha(root.foreground, 0.05)
    }

    Rectangle {
      anchors.left: parent.left
      anchors.top: parent.top
      anchors.bottom: parent.bottom
      width: parent.width * root.clamp(modelRow.share, 0, 1)
      radius: Style.cornerRadius
      color: root.alpha(root.foreground, 0.14)

      Behavior on width {
        NumberAnimation { duration: root.motion(160); easing.type: Easing.OutCubic }
      }
    }

    Text {
      id: modelName
      textFormat: Text.PlainText
      text: modelRow.row ? modelRow.row.name : ""
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
      elide: Text.ElideRight
      anchors.left: parent.left
      anchors.leftMargin: Style.space(8)
      anchors.right: modelTokens.left
      anchors.rightMargin: Style.space(8)
      anchors.verticalCenter: parent.verticalCenter
    }

    Text {
      id: modelTokens
      text: modelRow.row ? usage.formatTokenCount(modelRow.row.total) : ""
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
      font.bold: true
      anchors.right: parent.right
      anchors.rightMargin: Style.space(8)
      anchors.verticalCenter: parent.verticalCenter
    }

    MouseArea {
      id: modelHover
      anchors.fill: parent
      hoverEnabled: true
      acceptedButtons: Qt.NoButton
    }

    PanelToolTip {
      visible: modelHover.containsMouse
      text: root.modelTooltip(modelRow.row)
      fontFamily: root.fontFamily
    }
  }

  // Remaining leftover vs time. Plateaus are stored as t..until so idle
  // polls collapse to a horizontal run; a steep drop is a fast spend.
  // Fill under the line (Canvas path from first sample to last) so a 100%
  // leftover or a single sample still reads, without rectangle seam lines.
  component RemainingChart: Column {
    id: chart
    property var series: []
    property bool showHeader: true

    spacing: Style.space(2)

    Item {
      visible: chart.showHeader
      width: parent.width
      implicitHeight: Math.max(remainTitle.implicitHeight, remainHint.implicitHeight)

      Text {
        id: remainTitle
        text: "Remaining"
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
      }

      Text {
        id: remainHint
        text: "Steeper drop = faster spend"
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
      }
    }

    Item {
      id: plot
      width: parent.width
      height: Style.space(84)
      clip: true
      readonly property real plotLeft: 36
      readonly property real plotRight: 8
      readonly property real plotTop: 10
      readonly property real plotBottom: 10
      readonly property var plotLayout: root.opened
        ? root.remainingPlotLayout(chart.series, width, height, root.nowMs, root.remainingAxis) : ({})
      readonly property var hoverBounds: root.remainingBounds(chart.series, root.nowMs, root.remainingAxis)
      readonly property bool hoverActive: chartHover.containsMouse
        && chartHover.mouseX >= plotLeft && chartHover.mouseX <= width - plotRight
      readonly property real hoverX: hoverActive ? chartHover.mouseX : -1
      readonly property real hoverTimeMs: {
        if (!hoverActive) return NaN
        var span = Number(hoverBounds.max) - Number(hoverBounds.min)
        var ratio = root.clamp((hoverX - plotLeft) / Math.max(1, width - plotLeft - plotRight), 0, 1)
        return Number(hoverBounds.min) + ratio * span
      }
      readonly property var hoverValues: hoverActive
        ? root.remainingValuesAt(chart.series, hoverTimeMs, root.nowMs, hoverBounds) : []
      readonly property bool hoverHasValues: hoverValues.length > 0

      function yForHover(value) {
        return plotTop + Math.max(1, height - plotTop - plotBottom) * (1 - root.clamp(Number(value), 0, 1))
      }

      function labelYForHover(index, labelHeight) {
        if (index < 0 || index >= hoverValues.length) return plotTop
        var gap = Style.space(4)
        var lineY = yForHover(hoverValues[index].y)
        var y = lineY - labelHeight - gap
        if (y < plotTop) y = lineY + gap
        y = root.clamp(y, plotTop, height - plotBottom - labelHeight)
        // Two almost-overlapping series still need two readable value rows.
        if (index > 0) {
          var previousY = labelYForHover(index - 1, labelHeight)
          if (Math.abs(y - previousY) < labelHeight) {
            var below = lineY + gap
            y = below + labelHeight <= height - plotBottom
              ? below
              : Math.max(plotTop, previousY - labelHeight)
          }
        }
        return y
      }

      Rectangle {
        anchors.fill: parent
        radius: 4
        color: root.alpha(root.foreground, 0.08)
      }

      // Continuous under-curve fill (first..last sample only). Canvas path
      // avoids the vertical seam lines from adjacent Rectangle strips.
      Canvas {
        id: remainFill
        anchors.fill: parent
        // Do not declare `baseline` / `areas` — Item/Canvas treat some of
        // those names as FINAL and the whole widget fails to load.
        readonly property var fillAreas: (plot.plotLayout && plot.plotLayout.areas) ? plot.plotLayout.areas : []
        readonly property real fillYZero: plot.plotLayout && plot.plotLayout.yZero ? Number(plot.plotLayout.yZero) : height - 10
        readonly property string fill0: root.remainingCss(root.alpha(root.foreground, 0.12))
        readonly property string fill1: root.remainingCss(root.alpha(root.foreground, 0.06))

        onFillAreasChanged: requestPaint()
        onFillYZeroChanged: requestPaint()
        onFill0Changed: requestPaint()
        onFill1Changed: requestPaint()
        onWidthChanged: requestPaint()
        onHeightChanged: requestPaint()

        onPaint: {
          var ctx = getContext("2d")
          ctx.reset()
          ctx.clearRect(0, 0, width, height)
          var list = fillAreas || []
          var yBase = fillYZero
          for (var s = 0; s < list.length; s++) {
            var area = list[s] || {}
            var pts = area.points || []
            if (pts.length < 2) continue
            ctx.beginPath()
            ctx.moveTo(Number(pts[0].x), yBase)
            for (var i = 0; i < pts.length; i++)
              ctx.lineTo(Number(pts[i].x), Number(pts[i].y))
            ctx.lineTo(Number(pts[pts.length - 1].x), yBase)
            ctx.closePath()
            ctx.fillStyle = Number(area.series) === 0 ? fill0 : fill1
            ctx.fill()
          }
        }
      }

      Repeater {
        model: [0, 0.5, 1]
        Rectangle {
          required property var modelData
          width: plot.width - 44
          height: 1
          x: 36
          y: 10 + (plot.height - 20) * (1 - Number(modelData))
          color: root.alpha(root.foreground, 0.18)
        }
      }

      Text {
        text: "100%"
        x: 2
        y: 2
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
      }

      Text {
        text: "50%"
        x: 2
        anchors.verticalCenter: parent.verticalCenter
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
      }

      Text {
        text: "0%"
        x: 2
        anchors.bottom: parent.bottom
        anchors.bottomMargin: 2
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
      }

      Repeater {
        model: (plot.plotLayout && plot.plotLayout.paces) ? plot.plotLayout.paces : []
        Rectangle {
          required property var modelData
          width: Number(modelData.width)
          height: 1
          x: Number(modelData.x)
          y: Number(modelData.y)
          antialiasing: true
          color: root.alpha(root.urgent, Number(modelData.alpha !== undefined ? modelData.alpha : 0.85))
          transformOrigin: Item.Left
          rotation: Number(modelData.rotation)
        }
      }

      Repeater {
        model: (plot.plotLayout && plot.plotLayout.lines) ? plot.plotLayout.lines : []
        Rectangle {
          required property var modelData
          width: Number(modelData.width)
          height: 1
          x: Number(modelData.x)
          y: Number(modelData.y)
          antialiasing: true
          color: Number(modelData.series) === 0 ? root.foreground : root.alpha(root.foreground, 0.62)
          transformOrigin: Item.Left
          rotation: Number(modelData.rotation)
        }
      }

      Repeater {
        model: (plot.plotLayout && plot.plotLayout.dots) ? plot.plotLayout.dots : []
        Rectangle {
          required property var modelData
          width: 1.2
          height: 1.2
          x: Number(modelData.x)
          y: Number(modelData.y)
          radius: 0.6
          antialiasing: true
          color: Number(modelData.series) === 0 ? root.foreground : root.alpha(root.foreground, 0.62)
        }
      }

      Repeater {
        model: (plot.plotLayout && plot.plotLayout.resets) ? plot.plotLayout.resets : []
        Rectangle {
          required property var modelData
          x: Number(modelData.x)
          y: Number(modelData.y)
          width: Number(modelData.width)
          height: Number(modelData.height)
          color: root.alpha(root.foreground, 0.42)
        }
      }

      Repeater {
        model: (plot.plotLayout && plot.plotLayout.nows) ? plot.plotLayout.nows : []
        Rectangle {
          required property var modelData
          x: Number(modelData.x)
          y: Number(modelData.y)
          width: Number(modelData.width)
          height: Number(modelData.height)
          color: root.alpha(root.foreground, Number(modelData.series) === 0 ? 0.32 : 0.18)
        }
      }

      Rectangle {
        visible: plot.hoverActive && plot.hoverHasValues
        x: Math.round(plot.hoverX)
        y: plot.plotTop
        width: 1
        height: plot.height - plot.plotTop - plot.plotBottom
        color: root.alpha(root.foreground, 0.58)
      }

      Repeater {
        model: plot.hoverValues
        Rectangle {
          required property var modelData
          width: Style.space(5)
          height: width
          radius: width / 2
          x: plot.hoverX - width / 2
          y: plot.yForHover(modelData.y) - height / 2
          color: Number(modelData.series) === 0 ? root.foreground : root.alpha(root.foreground, 0.7)
          border.width: 1
          border.color: root.surface
        }
      }

      MouseArea {
        id: chartHover
        anchors.fill: parent
        hoverEnabled: true
        acceptedButtons: Qt.NoButton
        cursorShape: plot.hoverActive ? Qt.CrossCursor : Qt.ArrowCursor
      }

      Repeater {
        model: plot.hoverValues
        Text {
          required property var modelData
          required property int index
          visible: plot.hoverActive && plot.hoverHasValues
          text: (modelData.estimated ? "~" : "") + root.remainingPercentText(modelData.y)
          color: Number(modelData.series) === 0 ? root.foreground : root.alpha(root.foreground, 0.72)
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          font.bold: true
          x: {
            var gap = Style.space(6)
            var beside = plot.hoverX + gap
            if (beside + implicitWidth > plot.width - plot.plotRight)
              beside = plot.hoverX - implicitWidth - gap
            return Math.max(plot.plotLeft, beside)
          }
          // Each value follows its own line, offset vertically so the pointer
          // and the sampled dot cannot cover it.
          y: plot.labelYForHover(index, implicitHeight)
        }
      }
    }

    Item {
      width: parent.width
      implicitHeight: Style.font.caption + 2

      Text {
        text: root.remainingTick(root.remainingBounds(chart.series, root.nowMs, root.remainingAxis).min)
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        anchors.left: parent.left
      }

      Text {
        readonly property real nowX: plot.plotLayout && plot.plotLayout.nowX ? Number(plot.plotLayout.nowX) : -1
        visible: nowX > 56 && nowX < parent.width - 72
        text: "now"
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        x: nowX - implicitWidth / 2
      }

      Text {
        readonly property real resetX: plot.plotLayout && plot.plotLayout.resetX > 0 ? Number(plot.plotLayout.resetX) : -1
        readonly property real nowX: plot.plotLayout && plot.plotLayout.nowX ? Number(plot.plotLayout.nowX) : -1
        visible: resetX > 72 && resetX < parent.width - 80 && Math.abs(resetX - nowX) > 48
        text: "reset"
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        x: resetX - implicitWidth / 2
      }

      Text {
        text: root.remainingTick(root.remainingBounds(chart.series, root.nowMs, root.remainingAxis).max)
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        anchors.right: parent.right
      }
    }

    Flow {
      visible: !!(chart.series && chart.series.length > 1)
      width: parent.width
      spacing: Style.space(10)

      Repeater {
        model: chart.series
        Row {
          required property var modelData
          required property int index
          spacing: Style.space(4)

          Rectangle {
            width: Style.space(12)
            height: 1
            anchors.verticalCenter: parent.verticalCenter
            color: index === 0 ? root.foreground : root.alpha(root.foreground, 0.5)
          }

          Text {
            textFormat: Text.PlainText
            text: String((modelData && modelData.title) || "")
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }
        }
      }
    }
  }
}
