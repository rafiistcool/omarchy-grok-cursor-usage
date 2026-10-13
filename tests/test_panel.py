"""Exercise the real panel helpers with isolated data and no live collectors."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]
SHELL = Path(os.environ.get('OMARCHY_PATH', '/usr/share/omarchy')) / 'shell'


@unittest.skipUnless(shutil.which('qs') and (SHELL / 'Ui').is_dir() and os.environ.get('WAYLAND_DISPLAY'),
                     'requires Omarchy, Quickshell, and a Wayland session')
class PanelTests(unittest.TestCase):
    def test_provider_token_tables(self):
        with tempfile.TemporaryDirectory(prefix='agents-tables-') as temp:
            root = Path(temp)
            shutil.copytree(ROOT / 'plugin', root / 'plugin')
            (root / 'plugin/history.py').write_text('pass\n')
            for name in ('Commons', 'Ui', 'services'):
                (root / name).symlink_to(SHELL / name, target_is_directory=True)
            for name in ('collectors', 'runtime', 'state/omarchy/agents/usage'):
                (root / name).mkdir(parents=True, mode=0o700)
            collector = root / 'collectors/run-usage-update'
            collector.write_text('#!/bin/sh\nexit 0\n')
            collector.chmod(0o755)
            (root / 'shell.qml').write_text('''import QtQuick
import Quickshell
import "plugin" as Agents
ShellRoot {
  Agents.Panel { id: panel }
  function check(ok, message) { if (!ok) throw new Error(message) }
  function allItems(item, seen) {
    if (!item || seen.indexOf(item) >= 0) return seen
    seen.push(item)
    var lists = [item.data, item.children, item.contentItem]
    for (var i=0;i<lists.length;i++) {
      var list = lists[i]
      if (!list) continue
      if (list.length !== undefined) {
        for (var j=0;j<list.length;j++) allItems(list[j],seen)
      } else allItems(list,seen)
    }
    return seen
  }
  Timer {
    id: scrollCheck
    interval: 100
    onTriggered: {
      try {
        var flicks = allItems(panel,[]).filter(function(item) { return "flickableDirection" in item && "contentY" in item })
        // The popup stays closed during tests; give its scroll viewport a
        // small size and lay out the real rows without mapping an overlay.
        if (flicks.length === 1) {
          flicks[0].anchors.fill = null
          flicks[0].width = 380
          flicks[0].height = 200
          var items = allItems(panel,[])
          for (var i=items.length-1;i>=0;i--)
            if (typeof items[i].forceLayout === "function") items[i].forceLayout()
          var names = items.filter(function(item) { return item.text && String(item.text).startsWith("A Very Long Model") })
          check(names.length === 4 && names.every(function(item) {
            return item.elide === Text.ElideRight && item.implicitWidth > item.width
          }), "long model names elide within rows: " + JSON.stringify(names.map(function(item) { return [item.text,item.elide,item.implicitWidth,item.width] })))
        }
        check(flicks.length === 1 && flicks[0].contentHeight > flicks[0].height && flicks[0].interactive,
          "overflow enables scrolling: " + flicks.length + " " + (flicks.length ? flicks[0].contentHeight+"/"+flicks[0].height : ""))
        flicks[0].contentY = 100
        check(flicks[0].contentY === 100, "scroll position advances")
        console.log("AGENTS_TABLES_PASS")
      } catch (error) { console.log("AGENTS_TABLES_FAIL", error) }
      Qt.quit()
    }
  }
  Timer {
    interval: 400; running: true
    onTriggered: {
      try {
        var service = Agents.UsageService
        var first = {id:"first", todayPrompts:3, todaySessions:1,
          recentDays:[{date:"2026-10-04",messageCount:1000},{date:panel.todayDate(),messageCount:0}],
          modelUsage:{"gpt-6.1-sol":{inputTokens:100,outputTokens:20,cacheReadInputTokens:30,cacheCreationInputTokens:5}}}
        var second = {id:"second", todayPrompts:17, todaySessions:4,
          recentDays:[{date:panel.todayDate(),messageCount:2000}], modelUsage:{}}
        var today = second.recentDays[0]
        check(panel.dayTooltip(today,true,first).includes("3 prompts · 1 sessions"), "first tooltip")
        check(panel.dayTooltip(today,true,second).includes("17 prompts · 4 sessions"), "second tooltip")
        check(!panel.dayTooltip(today,false,first).includes("prompts"), "past-day tooltip")
        check(!panel.dayTooltip(today,true,{hasPromptStats:false}).includes("prompts"), "unavailable prompt stats")
        check(panel.weekPeak(first) === 1000 && panel.weekPeak(second) === 2000, "independent peaks")
        check(panel.dayLabel(today.date,true) === "Today", "today label")
        var rows = panel.modelRows(first)
        check(rows.length === 1 && rows[0].total === 155 && rows[0].name === "GPT 6.1 Sol", "model breakdown")
        check(panel.modelTooltip(rows[0]) === "In 100 · out 20 · cache read 30 · cache write 5", "model tooltip")
        var models = {}
        for (var i=1;i<=6;i++) models["a-very-long-model-name-that-needs-to-be-elided-even-on-a-wide-screen-with-extra-provider-and-version-details-"+i] = {outputTokens:i*100}
        rows = panel.modelRows({modelUsage:models})
        check(rows.length === 4 && rows[0].total === 600 && rows[3].total === 300, "top four models")
        check(panel.modelRows(null).length === 0 && panel.weekPeak(null) === 0, "empty data")
        check(service.providerHasData({todayTotalTokens:1}), "today tokens only")
        check(service.providerHasData({recentDays:first.recentDays}), "daily tokens only")
        check(service.providerHasData({modelUsage:first.modelUsage}), "model tokens only")
        check(service.providerHasData({modelUsage:{cached:{cacheReadInputTokens:1}}}), "cached tokens only")
        check(!service.providerHasData({recentDays:[{messageCount:0}],modelUsage:{}}), "empty provider")
        second.modelUsage = models
        service.agents = [{record:first},{record:second},{record:{id:"quota",limits:[{title:"Weekly",percent:.2}]}}]
        check(service.enabledProviders.length === 3, "token-only providers displayed")
        Qt.callLater(function() {
          try {
            var dayRows = function() { return allItems(panel,[]).filter(function(item) { return "day" in item && "ratio" in item }) }
            var modelRows = function() { return allItems(panel,[]).filter(function(item) { return "row" in item && "share" in item }) }
            check(dayRows().length === 0 && modelRows().length === 0, "token tables start folded")
            var folds = allItems(panel,[]).filter(function(item) { return "summary" in item && "open" in item && item.summary !== "" })
            check(folds.length === 4 && folds.every(function(item) { return !item.open }), "a folded table keeps its header and a summary")
            check(folds.some(function(item) { return item.summary === "GPT 6.1 Sol · 155" }), "model summary names the heaviest model")
            var byId = {}
            panel.providers.forEach(function(p) { byId[p.providerId] = p })
            check(panel.keyRows.some(function(row) { return row[0].kind === "days" }) && panel.keyRows.some(function(row) { return row[0].kind === "models" }),
              "the fold headers are cursor stops")
            panel.toggleTokenSection(byId.first, "days")
            check(panel.settings.openTokenSections.join() === "first.days" && panel.tokenSectionOpen(byId.first, "days"),
              "what's open is kept with the widget settings")
            check(dayRows().length === 2 && modelRows().length === 0, "one table opens on its own")
            panel.pointAt("days", panel.providers.map(function(p) { return p.providerId }).indexOf("first"))
            panel.activateSelection()
            check(panel.settings.openTokenSections.length === 0 && dayRows().length === 0, "activating the header again folds it")
            panel.settings = {openTokenSections:["first.days","first.models","second.days","second.models"]}
            var days = dayRows()
            var models = modelRows()
            check(days.length === 3 && models.length === 5, "rendered table rows")
            var firstDays = days.filter(function(item) { return item.provider.providerId === "first" })
            check(firstDays.length === 2, "daily rows retain provider")
            check(firstDays.some(function(item) { return item.ratio === 0 && item.today }), "zero-token today row")
            check(days.some(function(item) { return item.provider.providerId === "second" && item.ratio === 1 }), "independent daily scaling")
            check(models.filter(function(item) { return item.share === 1 }).length === 2, "independent model scaling")
            var records = service.agents.slice()
            for (var i=0;i<8;i++) {
              var extra = JSON.parse(JSON.stringify(first))
              extra.id = "extra-"+i
              records.push({record:extra})
            }
            service.agents = records
            scrollCheck.start()
          } catch (error) { console.log("AGENTS_TABLES_FAIL", error); Qt.quit() }
        })
      } catch (error) { console.log("AGENTS_TABLES_FAIL", error); Qt.quit() }
    }
  }
}
''')
            display = Path(os.environ['WAYLAND_DISPLAY'])
            if not display.is_absolute():
                display = Path(os.environ['XDG_RUNTIME_DIR']) / display
            env = dict(os.environ, QT_QPA_PLATFORM='wayland', WAYLAND_DISPLAY=str(display),
                       XDG_RUNTIME_DIR=str(root / 'runtime'), XDG_STATE_HOME=str(root / 'state'))
            result = subprocess.run(['qs', '-p', str(root), '--no-color'], env=env,
                                    capture_output=True, text=True, timeout=10)
            output = result.stdout + result.stderr
            self.assertEqual(result.returncode, 0, output)
            self.assertIn('AGENTS_TABLES_PASS', output)
            self.assertNotIn('AGENTS_TABLES_FAIL', output)

    def test_accounts_switching_and_plain_text(self):
        with tempfile.TemporaryDirectory(prefix='agents-accounts-') as temp:
            root = Path(temp)
            shutil.copytree(ROOT / 'plugin', root / 'plugin')
            (root / 'plugin/history.py').write_text('pass\n')
            for name in ('Commons', 'Ui', 'services'):
                (root / name).symlink_to(SHELL / name, target_is_directory=True)
            for name in ('collectors', 'runtime', 'home', 'bin', 'state/omarchy/agents/usage'):
                (root / name).mkdir(parents=True, mode=0o700)
            # Every account helper is a fake that only records its arguments;
            # the isolated HOME and state keep a real one harmless regardless.
            log = root / 'helpers.log'
            log.write_text('')
            for name in ('run-usage-update', 'omarchy-agent-account-add', 'omarchy-agent-account-use',
                         'omarchy-agent-account-mode', 'omarchy-agent-account-rename'):
                helper = root / ('collectors' if name == 'run-usage-update' else 'bin') / name
                helper.write_text('#!/bin/sh\necho "' + name + ' $*" >> "$AGENTS_HELPER_LOG"\n')
                helper.chmod(0o755)
            (root / 'shell.qml').write_text('''import QtQuick
import Quickshell
import "plugin" as Agents
ShellRoot {
  Agents.Panel { id: panel }
  function check(ok, message) { if (!ok) throw new Error(message) }
  function allItems(item, seen) {
    if (!item || seen.indexOf(item) >= 0) return seen
    seen.push(item)
    var lists = [item.data, item.children, item.contentItem]
    for (var i=0;i<lists.length;i++) {
      var list = lists[i]
      if (!list) continue
      if (list.length !== undefined) {
        for (var j=0;j<list.length;j++) allItems(list[j],seen)
      } else allItems(list,seen)
    }
    return seen
  }
  function kinds(row) { return row.map(function(target) { return target.kind + target.index }).join(",") }
  Timer {
    interval: 400; running: true
    onTriggered: {
      try {
        var service = Agents.UsageService
        service.accountTools = true
        var soon = new Date(Date.now() + 3600000).toISOString()
        var past = new Date(Date.now() - 3600000).toISOString()
        var limits = [{label:"Session (5-hour)",percent:.85,resetsAt:soon},{label:"Old",title:"<s>Expired</s>",percent:.99,resetsAt:past}]
        var claude = {id:"claude", name:"Claude <b>Code</b>", ready:true, tierLabel:"<u>Max</u>", limits:limits,
          accountSwitch:{mode:"manual",threshold:95}, accounts:[
            {id:"main",label:"Main",email:"me@example.invalid",plan:"Max 20x",active:true,primary:true,limits:limits},
            {id:"work",label:"<img src=x>Work",plan:"<i>Pro</i>",active:false,limits:[{label:"Weekly (7-day)",percent:.2,resetsAt:soon}],stale:true,fetchedAt:1},
            {id:"side",label:"Side",active:false,limits:[],usageStatusText:"Waiting for auth",authHelpText:"<b>help</b>"}]}
        var grok = {id:"grok", name:"Grok", usageStatusText:"Sign-in expired", authHelpText:"Run <b>grok login</b>.",
          limits:[{title:"Weekly",percent:.4,resetsAt:soon}]}
        var cursor = {id:"cursor", name:"Cursor", usageStatusText:"Waiting for auth", authHelpText:"Sign in to the <b>Cursor</b> app.",
          limits:[{title:"Monthly",percent:.5,resetsAt:soon}]}
        service.agents = [{record:claude},{record:grok},{record:cursor}]
        check(service.enabledProviders.map(function(p) { return p.providerId }).join() === "grok,cursor,claude", "default order")
        check(service.nearLimit, "several accounts near the switch threshold refresh sooner")
        Qt.callLater(function() {
          try {
            var byId = {}
            panel.providers.forEach(function(p) { byId[p.providerId] = p })
            check(panel.accountEntries.length === 3, "accounts listed across providers")
            check(panel.signInOffered(byId.grok) && !panel.signInOffered(byId.cursor), "sign-in offered only where it can be done")
            check(panel.providerNotice(byId.grok) === "" && panel.providerNotice(byId.cursor).indexOf("Cursor") >= 0, "other agents keep their help line")
            var rows = panel.keyRows.map(kinds)
            check(rows.join("|") === "add0,launch0|provider0|providerSignin0|provider1|provider2|autoswitch1,account1|signin2,autoswitch2,account2|starter0,starter1,starter2",
              "cursor stops: " + rows.join("|"))
            var expired = panel.limitWindows(byId.claude)[1]
            check(expired.percent === 0 && expired.resetAt === "", "a window past its reset reads empty")
            var unknown = {title:"Odd", percent:.2, resetAt:soon, startsAt:""}
            check(panel.paceRemaining(unknown) === -1 && panel.paceCaption(unknown) === "", "no pace without a window start")
            check(panel.inferredWindowSpanMs({title:"Fable Weekly"}) === 7 * 24 * 3600 * 1000, "a model-scoped window shares its clock")

            panel.pointAt("account", 0)
            check(!panel.pickedEntry, "the active account is not a stop")
            panel.pointAt("account", 1)
            check(panel.pickedEntry.account.id === "work" && panel.isPicked(byId.claude, byId.claude.accounts[1]), "picked account")
            panel.activateSelection()
            panel.toggleSwitchMode()
            panel.renameAccount(byId.claude, byId.claude.accounts[1], "Day job")

            var items = allItems(panel, [])
            check(items.filter(function(item) { return "pickedKind" in item }).length === 3, "one header per account")
            check(items.filter(function(item) { return "leftover" in item && "stale" in item && item.stale }).length === 1, "stale account limits marked")
            var markup = items.filter(function(item) { return typeof item.text === "string" && "textFormat" in item && /<\\w/.test(item.text) })
            check(markup.length >= 6, "markup-shaped strings reach the page: " + markup.length)
            var rich = markup.filter(function(item) { return item.textFormat !== Text.PlainText })
            check(rich.length === 0, "collector text stays plain: " + JSON.stringify(rich.map(function(item) { return item.text })))

            // A release without `omarchy agent account` offers none of it.
            service.accountTools = false
            check(!panel.addButtonShown && !panel.signInOffered(byId.grok), "account controls need the account tools")
            check(panel.providerNotice(byId.grok).indexOf("grok login") >= 0, "the help line stands in for the link")
            check(panel.keyRows.map(kinds).join("|").indexOf("add0") < 0 && panel.keyRows.map(kinds).join("|").indexOf("providerSignin") < 0, "no stops for missing controls")
            panel.addAccount()
            check(panel.addStage === "", "adding needs the account tools")
            console.log("AGENTS_ACCOUNTS_PASS")
          } catch (error) { console.log("AGENTS_ACCOUNTS_FAIL", error) }
          Qt.quit()
        })
      } catch (error) { console.log("AGENTS_ACCOUNTS_FAIL", error); Qt.quit() }
    }
  }
}
''')
            display = Path(os.environ['WAYLAND_DISPLAY'])
            if not display.is_absolute():
                display = Path(os.environ['XDG_RUNTIME_DIR']) / display
            env = dict(os.environ, QT_QPA_PLATFORM='wayland', WAYLAND_DISPLAY=str(display),
                       HOME=str(root / 'home'), XDG_CONFIG_HOME=str(root / 'home/.config'),
                       XDG_RUNTIME_DIR=str(root / 'runtime'), XDG_STATE_HOME=str(root / 'state'),
                       AGENTS_HELPER_LOG=str(log), PATH=str(root / 'bin') + os.pathsep + os.environ['PATH'])
            result = subprocess.run(['qs', '-p', str(root), '--no-color'], env=env,
                                    capture_output=True, text=True, timeout=10)
            output = result.stdout + result.stderr
            self.assertEqual(result.returncode, 0, output)
            self.assertIn('AGENTS_ACCOUNTS_PASS', output)
            self.assertNotIn('AGENTS_ACCOUNTS_FAIL', output)
            # The helpers are started detached, so they may land after the shell quits.
            expected = ['omarchy-agent-account-use claude work', 'omarchy-agent-account-mode claude auto',
                        'run-usage-update --limits-only claude', 'omarchy-agent-account-rename claude work Day job']
            deadline = time.monotonic() + 5
            while time.monotonic() < deadline and not all(line in log.read_text() for line in expected):
                time.sleep(.05)
            for line in expected:
                self.assertIn(line, log.read_text())


if __name__ == '__main__':
    unittest.main()
