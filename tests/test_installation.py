import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


@unittest.skipUnless(shutil.which('omarchy-plugin-add'), 'requires Omarchy CLI')
class InstallationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='agents install ')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.source = self.root / 'source'
        self.home = self.root / 'home'
        self.home.mkdir()
        shutil.copytree(ROOT, self.source, ignore=shutil.ignore_patterns('.git', '__pycache__'))
        self.bin = self.root / 'bin'
        self.bin.mkdir()
        # Isolate desktop IPC only; clone, validation, catalog, and update are real.
        shell = self.bin / 'omarchy-shell'
        shell.write_text('#!/bin/sh\nexit 0\n')
        shell.chmod(0o755)
        self.env = dict(os.environ, HOME=str(self.home), XDG_CONFIG_HOME=str(self.home / '.config'),
                        XDG_STATE_HOME=str(self.home / '.local/state'),
                        PATH=str(self.bin) + os.pathsep + os.environ['PATH'],
                        GIT_CONFIG_NOSYSTEM='1', GIT_CONFIG_GLOBAL='/dev/null')
        self.run_cmd('git', 'init', '-b', 'main', str(self.source))
        self.run_cmd('git', '-C', str(self.source), 'config', 'user.email', 'test@example.invalid')
        self.run_cmd('git', '-C', str(self.source), 'config', 'user.name', 'Installation Test')
        self.run_cmd('git', '-C', str(self.source), 'remote', 'add', 'origin', str(self.source))
        self.commit('initial')
        self.installed = self.home / '.config/omarchy/plugins/rafi.agents'

    def run_cmd(self, *args, check=True):
        result = subprocess.run(args, env=self.env, capture_output=True, text=True, timeout=10)
        if check:
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return result

    def commit(self, message):
        self.run_cmd('git', '-C', str(self.source), 'add', '.')
        self.run_cmd('git', '-C', str(self.source), 'commit', '-m', message)

    def test_native_add_and_update(self):
        self.run_cmd('omarchy-plugin-add', str(self.source), '--yes')
        self.assertTrue((self.installed / '.git').is_dir())
        manifest = json.loads((self.installed / 'manifest.json').read_text())
        self.assertTrue((self.installed / manifest['entryPoints']['barWidget']).is_file())
        self.assertTrue(os.access(self.installed / 'collectors/run-usage-update', os.X_OK))
        (self.source / 'update-marker').write_text('updated\n')
        self.commit('update')
        self.run_cmd('omarchy-plugin-update', 'rafi.agents', '--yes')
        self.assertEqual((self.installed / 'update-marker').read_text(), 'updated\n')
        self.assertEqual(self.run_cmd('git', '-C', str(self.installed), 'status', '--porcelain').stdout, '')

    def test_legacy_migration_preserves_settings_and_backup(self):
        self.installed.mkdir(parents=True)
        (self.installed / 'old-file').write_text('keep me')
        shell_json = self.home / '.config/omarchy/shell.json'
        config = {'bar': {'layout': {'right': [{'id': 'omarchy.agents', 'remainingAxis': 'cycle'}, {'id': 'omarchy.audio'}]}}, 'idle': {'lock': 600}}
        shell_json.write_text(json.dumps(config))
        self.run_cmd(str(self.source / 'install.sh'), '--force', '--apply-layout')
        installed_config = json.loads(shell_json.read_text())
        self.assertEqual(installed_config['bar']['layout']['right'][0], {'id': 'rafi.agents', 'remainingAxis': 'cycle'})
        self.assertEqual(installed_config['idle'], config['idle'])
        backups = list((self.home / '.local/state/omarchy/plugin-backups').glob('*/plugin/old-file'))
        self.assertEqual(len(backups), 1)
        self.assertEqual(backups[0].read_text(), 'keep me')
        self.assertTrue((self.installed / '.git').is_dir())
        self.assertTrue(list(shell_json.parent.glob('shell.json.bak.*')))
        # Running from an installed checkout must not try to overwrite itself.
        self.run_cmd(str(self.installed / 'install.sh'), '--force')

    def test_dirty_source_is_not_silently_installed(self):
        (self.source / 'uncommitted-file').write_text('pending')
        result = self.run_cmd(str(self.source / 'install.sh'), check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.installed.exists())


if __name__ == '__main__':
    unittest.main()
