"""Exercise the real panel helpers with isolated data and no live collectors."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
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
            var items = allItems(panel,[])
            var days = items.filter(function(item) { return "day" in item && "ratio" in item })
            var models = items.filter(function(item) { return "row" in item && "share" in item })
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


if __name__ == '__main__':
    unittest.main()
