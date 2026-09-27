"""Exercise shared history and outage backoff with isolated QML and no collectors."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]

@unittest.skipUnless(shutil.which('qs'), 'requires Quickshell')
class ServiceTests(unittest.TestCase):
    def test_shared_history_and_bounded_retries(self):
        with tempfile.TemporaryDirectory(prefix='agents-idle-') as temp:
            root = Path(temp)
            for name in ('plugin','collectors','runtime','state/omarchy/agents/usage'):
                (root/name).mkdir(parents=True,mode=0o700)
            for name in ('Main.qml','Agent.qml','UsageService.qml','qmldir'):
                shutil.copy2(ROOT/'plugin'/name,root/'plugin'/name)
            (root/'plugin/history.py').write_text('pass\n')
            collector=root/'collectors/run-usage-update'
            collector.write_text('#!/bin/sh\nexit 0\n');collector.chmod(0o755)
            (root/'shell.qml').write_text('''import QtQuick
import Quickshell
import "plugin" as Agents
ShellRoot {
  property var service: Agents.UsageService
  property var otherMonitor: Agents.UsageService
  Timer {
    interval: 300; running: true
    onTriggered: {
      if (service !== otherMonitor) { console.log("DUPLICATE_BACKEND"); Qt.quit(); return }
      service.applyHistory("antigravity", '{"series":[{"title":"Keep me"}]}')
      service.applyHistory("grokbot", '{"series":[]}')
      service.applyHistory("grok", '{"series":[]}')
      if (!service.remainingHistory.antigravity || !service.remainingHistory.grokbot) {
        console.log("LOST_HISTORY"); Qt.quit(); return
      }
      service.agents = [{record:{id:"grok",retryAdvised:true}}]
      service.scheduleLimitsRetry()
      if (service.retryAgentIds.join() !== "grok" || service.retryDelayMs !== 30000) {
        console.log("BAD_FIRST_RETRY"); Qt.quit(); return
      }
      service.retryAttempt = 1
      if (service.retryDelayMs !== 60000) { console.log("BAD_BACKOFF"); Qt.quit(); return }
      service.retryAttempt = 20
      if (service.retryDelayMs !== 900000) { console.log("BAD_CAP"); Qt.quit(); return }
      service.agents = []
      service.scheduleLimitsRetry()
      if (service.retryAttempt !== 0) { console.log("BAD_RESET"); Qt.quit(); return }
      console.log("AGENTS_IDLE_PASS"); Qt.quit()
    }
  }
}
''')
            env=dict(os.environ,QT_QPA_PLATFORM='offscreen',XDG_RUNTIME_DIR=str(root/'runtime'),XDG_STATE_HOME=str(root/'state'))
            result=subprocess.run(['qs','-p',str(root),'--no-color'],env=env,capture_output=True,text=True,timeout=8)
            self.assertEqual(result.returncode,0,result.stdout+result.stderr)
            self.assertIn('AGENTS_IDLE_PASS',result.stdout+result.stderr)
