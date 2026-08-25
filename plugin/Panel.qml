import QtQuick
import QtQuick.Controls
import QtQuick.Effects
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

Panel {
  id: root
  moduleName: "yourname.agents"
  ipcTarget: "yourname.agents"
  manageIpc: false

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property color surface: Color.popups.background
  readonly property color track: Style.selectedFillFor(foreground, Color.accent)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

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

  readonly property var limits: limitWindows(provider)
  readonly property var models: modelRows(provider)
  readonly property var headline: bindingWindow(provider)
  readonly property var balance: provider ? (provider.balance || null) : null
  // A prepaid account runs low the way a subscription window fills up: the
  // last 10% of the funded credits lights the same alarm.
  readonly property bool balanceAlarming: !!balance && balance.funded > 0
    && balance.remaining / balance.funded <= 0.1
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
  readonly property var stackedProviders: {
    var grok = [], cursor = [], rest = []
    var list = providers || []
    for (var i = 0; i < list.length; i++) {
      var id = String(list[i].providerId || "")
      if (id === "grok") grok.push(list[i])
      else if (id === "cursor") cursor.push(list[i])
      else rest.push(list[i])
    }
    return grok.concat(cursor).concat(rest)
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

  property var grokRemaining: null
  property var cursorRemaining: null
  property var codexRemaining: null
  readonly property string agentsHistoryDir: (Quickshell.env("XDG_STATE_HOME") || ((Quickshell.env("HOME") || "") + "/.local/state")) + "/omarchy/agents/history"

  function clamp(v, lo, hi) { return Math.max(lo, Math.min(hi, v)) }
  function alpha(c, a) { return Qt.rgba(c.r, c.g, c.b, a) }

  function settingNumber(name, fallback, min, max) {
    var n = Number(setting(name, fallback))
    if (!isFinite(n)) n = fallback
    return clamp(Math.round(n), min, max)
  }

  function persistSettings(values) {
    var id = root.moduleName || "yourname.agents"
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

  function refreshNow() {
    usage.refreshAll(true)
  }

  function launchAgent() {
    if (root.bar) root.bar.run("omarchy-agent --pick")
    root.close()
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
    return {
      title: String(title || "") !== "" ? String(title) : windowTitle(label),
      percent: Number(percent),
      resetAt: String(resetAt || ""),
      startsAt: String(startAt || ""),
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
    if (!(end > start)) return -1
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
    if (id !== "grok" && id !== "cursor" && id !== "codex") return []
    var hist = id === "grok" ? root.grokRemaining : id === "cursor" ? root.cursorRemaining : root.codexRemaining
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

  // ---------------------------------------------------------------- content

  // The plan you pay for, under the name of the tool it pays for. Limits live
  // in their own section; the hero just says what this is.
  function heroMeta(p) {
    if (!p) return ""
    if (String(p.usageStatusText || "") !== "") return p.usageStatusText
    var tier = String(p.tierLabel || "")
    if (tier === "") return "Subscription"
    return tier.charAt(0).toUpperCase() + tier.slice(1)
  }

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

  function dayTooltip(day, today) {
    if (!day) return ""
    var parsed = new Date(String(day.date) + "T00:00:00")
    var label = isNaN(parsed.getTime())
      ? String(day.date)
      : dayName(day.date) + " " + (parsed.getMonth() + 1) + "/" + parsed.getDate()
    var text = label + " · " + usage.formatTokenCount(Number(day.messageCount || 0)) + " tokens"
    // Prompt and session counts only exist for today, so they ride along here
    // instead of taking a section of their own. Billing-API agents never
    // count prompts, and "0 prompts" would read as a quiet day, not a gap.
    if (today && provider && provider.hasPromptStats !== false)
      text += " · " + Number(provider.todayPrompts || 0) + " prompts · "
        + Number(provider.todaySessions || 0) + " sessions"
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
    if (provider && provider.syncEnabled && provider.syncDeviceCount > 0)
      return "Merged from " + provider.syncDeviceCount + " device" + (provider.syncDeviceCount === 1 ? "" : "s")
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
    if (colorLuminance(surfaceColor || Color.background) >= 0.5)
      candidates.push(Qt.resolvedUrl("assets/" + p.providerId + "-light.svg"))
    candidates.push(Qt.resolvedUrl("assets/" + p.providerId + ".svg"))
    return candidates
  }

  // Nothing to report, nothing in the bar: Bar.qml collapses a slot whose item
  // is invisible, so the icon appears the moment the first scan finds usage and
  // stays away entirely on a machine that has never run either CLI.
  visible: providers.length > 0
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onProviderIndexChanged: if (panelFlick) panelFlick.contentY = 0
  onOpenedChanged: if (opened) {
    cursorActive = false
    nowMs = Date.now()
    if (panelFlick) panelFlick.contentY = 0
    usage.refreshLimits()
    usage.scheduleHistory()
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  Main {
    id: usage
    settings: root.settings
  }

  FileView {
    path: root.agentsHistoryDir + "/grok.json"
    watchChanges: true
    printErrors: false
    Component.onCompleted: reload()
    onFileChanged: reload()
    onLoaded: root.grokRemaining = root.parseHistory(text())
    onLoadFailed: root.grokRemaining = null
  }

  FileView {
    path: root.agentsHistoryDir + "/cursor.json"
    watchChanges: true
    printErrors: false
    Component.onCompleted: reload()
    onFileChanged: reload()
    onLoaded: root.cursorRemaining = root.parseHistory(text())
    onLoadFailed: root.cursorRemaining = null
  }

  FileView {
    path: root.agentsHistoryDir + "/codex.json"
    watchChanges: true
    printErrors: false
    Component.onCompleted: reload()
    onFileChanged: reload()
    onLoaded: root.codexRemaining = root.parseHistory(text())
    onLoadFailed: root.codexRemaining = null
  }

  // Cheap enough to keep running: it only re-evaluates text bindings, and a
  // stale "resets in 2h" on a panel that is open is worse than a timer.
  Timer {
    interval: 30000
    running: true
    repeat: true
    onTriggered: root.nowMs = Date.now()
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

    Text {
      visible: root.remainingStyle === "logo-bar" || root.remainingStyle === "logo-on-bar" || root.remainingPct < 0
      anchors.centerIn: parent
      anchors.verticalCenterOffset: 2
      text: root.providerGlyph()
      color: root.alarming ? root.urgent : root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.bar.iconFont
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
        NumberAnimation { duration: 120; easing.type: Easing.OutCubic }
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

      onMoveRequested: function(dx, dy) {
        if (dy !== 0)
          panelFlick.contentY = root.clamp(panelFlick.contentY + dy * Style.space(56), 0,
                                           Math.max(0, panelFlick.contentHeight - panelFlick.height))
      }
      onActivateRequested: root.refreshNow()
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) { if (t === "r" || t === "R") root.refreshNow() }

      Flickable {
        id: panelFlick
        anchors.fill: parent
        contentWidth: width
        contentHeight: column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        Column {
          id: column
          width: panelFlick.width
          spacing: Style.space(12)

          Text {
            visible: root.stackedProviders.length === 0
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
            visible: root.stackedProviders.length > 0
            width: parent.width
            implicitHeight: Math.max(axisLabel.implicitHeight, axisGroup.implicitHeight)

            Text {
              id: axisLabel
              text: "Chart range"
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
            }

            ButtonGroup {
              id: axisGroup
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
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

          Repeater {
            model: root.stackedProviders

            ProviderBlock {
              required property var modelData
              required property int index
              width: column.width
              provider: modelData
              showDivider: index > 0
            }
          }

          Text {
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

  component ProviderBlock: Column {
    id: block
    property var provider: null
    property bool showDivider: false

    readonly property var windows: root.limitWindows(block.provider)
    spacing: Style.space(10)

    PanelSeparator {
      visible: block.showDivider
      width: parent.width
      foreground: root.foreground
    }

    PanelHero {
      width: parent.width
      title: block.provider ? String(block.provider.providerName || "") : ""
      meta: block.provider ? root.heroMeta(block.provider) : ""
      foreground: root.foreground
      fontFamily: root.fontFamily
      iconComponent: Component {
        Item {
          width: Style.font.display
          height: Style.font.display
          readonly property string pid: block.provider ? String(block.provider.providerId || "") : ""
          readonly property bool fontMark: pid === "grok" || pid === "codex"

          Text {
            visible: fontMark
            anchors.centerIn: parent
            text: pid === "grok" ? "\ue904" : "\ue905"
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: parent.height
          }

          // Always sample the light-on-transparent mark. The -light twin is
          // near-black and colorization cannot lift it to the theme ink.
          Image {
            id: markImage
            visible: false
            layer.enabled: !fontMark
            anchors.fill: parent
            source: fontMark || pid === "" ? "" : Qt.resolvedUrl("assets/" + pid + ".svg")
            sourceSize.width: Style.font.display * 2
            sourceSize.height: Style.font.display * 2
            fillMode: Image.PreserveAspectFit
          }

          MultiEffect {
            visible: !fontMark
            anchors.fill: markImage
            source: markImage
            colorization: 1.0
            colorizationColor: root.foreground
          }
        }
      }
    }

    Text {
      visible: text !== ""
      width: parent.width
      text: block.provider ? String(block.provider.authHelpText || block.provider.usageStatusText || "") : ""
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      wrapMode: Text.WordWrap
    }

    Repeater {
      model: block.windows
      LimitRow {
        required property var modelData
        width: block.width
        window: modelData
      }
    }

    RemainingChart {
      visible: {
        var id = block.provider ? String(block.provider.providerId || "") : ""
        if (id !== "grok" && id !== "cursor" && id !== "codex") return false
        var series = root.remainingSeriesFor(block.provider)
        return !!(series && series.length > 0)
      }
      width: parent.width
      series: root.remainingSeriesFor(block.provider)
    }
  }

  // Countdown meter: leftover fill. Monthly Cursor pools and Grok weekly
  // both use the even-burn tick when the window has a start/end.
  component LimitRow: Column {
    id: limitRow
    property var window: null

    readonly property bool alarming: window && window.percent >= 0.9
    readonly property real leftover: window && window.percent >= 0 ? (1 - window.percent) : -1

    spacing: Style.space(6)

    Item {
      width: parent.width
      implicitHeight: Math.max(limitLabel.implicitHeight, limitValue.implicitHeight)

      Text {
        id: limitLabel
        // A model-scoped window is titled after its model, and those names run
        // long enough to reach the percentage, so the title gives way first.
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
        color: limitRow.alarming ? root.urgent : root.foreground
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

    Text {
      id: resetText
      width: parent.width
      text: {
        var remainingMs = root.resetMsFor(limitRow.window)
        return remainingMs > 0 ? "Resets in " + root.formatDuration(remainingMs) : ""
      }
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
    }

    Text {
      visible: text !== ""
      width: parent.width
      text: root.paceCaption(limitRow.window)
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
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
        NumberAnimation { duration: 160; easing.type: Easing.OutCubic }
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

  // One row per day: label, bar, tokens. Today is picked out in full
  // foreground so the week reads as a run-up to right now.
  component DayRow: Item {
    id: dayRow
    property var day: null
    property real ratio: 0
    property bool today: false

    implicitHeight: Math.max(dayLabel.implicitHeight, dayValue.implicitHeight) + Style.spacing.sm

    Text {
      id: dayLabel
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
          NumberAnimation { duration: 160; easing.type: Easing.OutCubic }
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
      text: root.dayTooltip(dayRow.day, dayRow.today)
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
        NumberAnimation { duration: 160; easing.type: Easing.OutCubic }
      }
    }

    Text {
      id: modelName
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

    spacing: Style.space(2)

    Item {
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
      readonly property var plotLayout: root.remainingPlotLayout(chart.series, width, height, root.nowMs, root.remainingAxis)

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
