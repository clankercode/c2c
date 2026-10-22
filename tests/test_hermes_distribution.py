"""Distribution gate: check the public CLI against isolated canonical copies."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
CHECK = ROOT / 'tools/ci/check-hermes-distribution.py'


class HermesDistributionTests(unittest.TestCase):
    def test_crlf_embed_is_compared_without_newline_translation(self):
        with tempfile.TemporaryDirectory(dir=os.environ.get('TMPDIR')) as scratch:
            root = Path(scratch)
            skill = root / 'data/hermes-plugin/skills/c2c/SKILL.md'
            skill.parent.mkdir(parents=True)
            skill.write_bytes(b'# Skill\r\nGuidance\r\n')
            embed = root / 'ocaml/cli/c2c_hermes_plugin_embedded.ml'
            embed.parent.mkdir(parents=True)
            embed.write_bytes(b'  ("skills/c2c/SKILL.md", {src|' + skill.read_bytes() + b'|src});\r\n')
            command = ['python3', '-O', str(CHECK), '--root', str(root)]
            result = subprocess.run(command, capture_output=True, text=True, timeout=10)
            self.assertEqual(result.returncode, 0, result.stderr)
            # Equal after universal-newline translation is not byte equality.
            skill.write_bytes(b'# Skill\nGuidance\n')
            result = subprocess.run(command, capture_output=True, text=True, timeout=10)
            self.assertEqual(result.returncode, 1)
            self.assertIn('embedded: stale skills/c2c/SKILL.md', result.stderr)

    def test_distribution_and_installed_skill_drift(self):
        with tempfile.TemporaryDirectory(dir=os.environ.get('TMPDIR')) as scratch:
            root = Path(scratch)
            shutil.copytree(ROOT / 'data/hermes-plugin', root / 'data/hermes-plugin')
            (root / 'ocaml/cli').mkdir(parents=True)
            shutil.copy2(ROOT / 'ocaml/cli/c2c_hermes_plugin_embedded.ml', root / 'ocaml/cli')
            installed = root / 'installed'
            shutil.copytree(root / 'data/hermes-plugin', installed)

            def run(*args):
                return subprocess.run(['python3', str(CHECK), '--root', str(root), *args],
                                      capture_output=True, text=True, timeout=10)

            self.assertEqual(run().returncode, 0)
            self.assertEqual(run('--installed-dir', str(installed)).returncode, 0)
            skill = root / 'data/hermes-plugin/skills/c2c/SKILL.md'
            skill.write_text(skill.read_text() + '\nChanged guidance.\n')
            stale = run()
            self.assertEqual(stale.returncode, 1)
            self.assertIn('embedded: stale skills/c2c/SKILL.md', stale.stderr)
            skill.write_bytes((installed / 'skills/c2c/SKILL.md').read_bytes())
            (installed / 'skills/c2c/SKILL.md').write_text('outdated installed skill')
            stale = run('--installed-dir', str(installed))
            self.assertEqual(stale.returncode, 1)
            self.assertIn('installed: stale skills/c2c/SKILL.md', stale.stderr)
            # New files must be added to the real generator, not silently omitted.
            (root / 'data/hermes-plugin/new_adapter.py').write_text('# new source\n')
            self.assertIn('embedded: missing new_adapter.py', run().stderr)
            (root / 'data/hermes-plugin/runtime.json').write_text('{}')
            self.assertIn('embedded: missing runtime.json', run().stderr)


if __name__ == '__main__':
    unittest.main()
