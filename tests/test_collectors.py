import importlib.machinery
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]


def load_collector(name):
    loader = importlib.machinery.SourceFileLoader(name, str(ROOT / 'collectors' / ('omarchy-agent-usage-' + name)))
    spec = importlib.util.spec_from_loader(name, loader)
    module = importlib.util.module_from_spec(spec)
    loader.exec_module(module)
    return module


class RunnerTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='agents test ')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.bundled = self.root / 'repo/collectors'
        self.user = self.root / 'config/omarchy/agents'
        self.usage = self.root / 'state/omarchy/agents/usage'
        for directory in (self.bundled, self.user, self.root / 'repo/plugin', self.root / 'packaged/bin'):
            directory.mkdir(parents=True)
        shutil.copy2(ROOT / 'collectors/run-usage-update', self.bundled)
        shutil.copy2(ROOT / 'plugin/history.py', self.root / 'repo/plugin')
        self.env = dict(os.environ, HOME=str(self.root), XDG_CONFIG_HOME=str(self.root / 'config'),
                        XDG_STATE_HOME=str(self.root / 'state'), OMARCHY_PATH=str(self.root / 'packaged'))

    def collector(self, directory, agent, body=None):
        path = directory / ('omarchy-agent-usage-' + agent)
        path.write_text('#!/usr/bin/env python3\n' + (body or (
            'import json, sys\nprint(json.dumps({"schemaVersion":1,"id":' + repr(agent) + ',"args":sys.argv[1:]}))\n')))
        path.chmod(0o755)
        return path

    def run_update(self, *args):
        return subprocess.run([str(self.bundled / 'run-usage-update'), *args], env=self.env,
                              capture_output=True, text=True, timeout=5)

    def test_exclusions_selection_flags_and_xdg(self):
        for agent in ('grok', 'cursor', 'codex'):
            self.collector(self.bundled, agent)
        self.collector(self.user, 'extra')
        result = self.run_update('--force', '--limits-only', '--except', 'cursor', 'cursor', 'grok', 'extra')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(sorted(p.stem for p in self.usage.glob('*.json')), ['extra', 'grok'])
        self.assertEqual(json.loads((self.usage / 'grok.json').read_text())['args'], ['--force', '--limits-only'])

    def test_bundled_wins_over_legacy_copy_and_packaged_receives_exclusions(self):
        self.collector(self.bundled, 'grok')
        self.collector(self.user, 'grok', 'raise SystemExit(99)\n')
        self.collector(self.root / 'packaged/bin', 'update',
                       'import os, json, sys\nfrom pathlib import Path\nPath(os.environ["HOME"], "packaged-args.json").write_text(json.dumps(sys.argv[1:]))\n')
        result = self.run_update('--force', 'grok')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads((self.root / 'packaged-args.json').read_text()), ['--except', 'grok', '--force', 'grok'])
        self.assertTrue((self.usage / 'grok.json').is_file())

    def test_failure_does_not_block_another_provider_or_replace_last_record(self):
        self.usage.mkdir(parents=True)
        old = '{"id":"grok","schemaVersion":1,"previous":true}\n'
        (self.usage / 'grok.json').write_text(old)
        self.collector(self.bundled, 'grok', 'print("[]")\n')
        self.collector(self.bundled, 'cursor')
        result = self.run_update()
        self.assertEqual(result.returncode, 1)
        self.assertEqual((self.usage / 'grok.json').read_text(), old)
        self.assertTrue((self.usage / 'cursor.json').is_file())

    def test_collectors_run_concurrently(self):
        # First collector cannot finish until the second starts.
        self.collector(self.bundled, 'a', 'import os, time\nfrom pathlib import Path\n'
                       'p=Path(os.environ["HOME"], "started")\n'
                       'for _ in range(40):\n if p.exists(): break\n time.sleep(.025)\n'
                       'else: raise SystemExit(1)\nprint(\'{"schemaVersion":1,"id":"a"}\')\n')
        self.collector(self.bundled, 'b', 'import os\nfrom pathlib import Path\n'
                       'Path(os.environ["HOME"], "started").touch()\nprint(\'{"schemaVersion":1,"id":"b"}\')\n')
        result = self.run_update()
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_invalid_arguments(self):
        for args in [('--except',), ('--except', '--force'), ('--unknown',)]:
            with self.subTest(args=args):
                self.assertEqual(self.run_update(*args).returncode, 2)

    def test_history_written_without_panel(self):
        record = dict(schemaVersion=1, id='grok', updatedAt='2026-09-27T12:00:00Z',
                      limits=[dict(title='Weekly', percent=.25, startsAt='2026-09-25T00:00:00Z', resetsAt='2026-10-02T00:00:00Z')])
        self.collector(self.bundled, 'grok', 'print(' + repr(json.dumps(record)) + ')\n')
        result = self.run_update()
        self.assertEqual(result.returncode, 0, result.stderr)
        history = json.loads((self.usage.parent / 'history/grok.json').read_text())
        self.assertEqual(history['series'][0]['points'][0]['remaining'], .75)


class CodexRPCTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.codex = load_collector('codex')

    def process(self, code):
        proc = subprocess.Popen([sys.executable, '-u', '-c', code], stdin=subprocess.PIPE,
                                stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, bufsize=0)
        def cleanup():
            if proc.poll() is None:
                proc.kill()
            proc.wait(timeout=2)
            proc.stdin.close()
            proc.stdout.close()
        self.addCleanup(cleanup)
        return proc

    def test_notification_and_response_in_one_write(self):
        proc = self.process('import sys,time\nsys.stdin.readline()\nsys.stdout.write(\'{"method":"notice"}\\n{"id":1,"result":{"ok":true}}\\n\')\nsys.stdout.flush()\ntime.sleep(3)')
        self.assertTrue(self.codex.rpc_request(proc, 1, 'test', timeout=.5)['result']['ok'])

    def test_partial_line_obeys_deadline(self):
        proc = self.process('import sys,time\nsys.stdin.readline()\nsys.stdout.write(\'{"id":\')\nsys.stdout.flush()\ntime.sleep(3)')
        start = time.monotonic()
        with self.assertRaises(TimeoutError):
            self.codex.rpc_request(proc, 1, 'test', timeout=.15)
        self.assertLess(time.monotonic() - start, .8)

    def test_rpc_error_is_not_success(self):
        proc = self.process('import sys,time\nsys.stdin.readline()\nprint(\'{"id":1,"error":{"code":-1}}\',flush=True)\ntime.sleep(3)')
        with self.assertRaisesRegex(RuntimeError, 'RPC failed'):
            self.codex.rpc_request(proc, 1, 'test', timeout=.5)

    def test_timeout_terminates_server_without_blocking_on_stderr(self):
        proc = self.process('import time\ntime.sleep(3)')
        start = time.monotonic()
        with patch.object(self.codex, 'find_command', return_value='fake-codex'), \
             patch.object(self.codex.subprocess, 'Popen', return_value=proc), \
             patch.object(self.codex, 'rpc_request', side_effect=TimeoutError('initialize')):
            result = self.codex.fetch_codex_rpc()
        self.assertEqual(result['usageStatusText'], 'Codex limits unavailable')
        self.assertIsNotNone(proc.poll())
        self.assertLess(time.monotonic() - start, .8)


class AntigravityTests(unittest.TestCase):
    def test_unavailable_app_emits_successful_status_record(self):
        import contextlib
        import io
        collector = load_collector('antigravity')
        output = io.StringIO()
        record = {"schemaVersion": 1, "id": "antigravity", "ready": False}
        with patch.object(collector, 'collect', return_value=record), \
             patch.object(sys, 'argv', ['collector']), contextlib.redirect_stdout(output):
            self.assertEqual(collector.main(), 0)
        self.assertEqual(json.loads(output.getvalue()), record)


if __name__ == '__main__':
    unittest.main()
