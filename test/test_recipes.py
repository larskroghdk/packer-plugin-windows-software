import importlib.util
import json
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location('resolve', 'scripts/resolve.py')
resolve = importlib.util.module_from_spec(spec)
spec.loader.exec_module(resolve)


class Recipes(unittest.TestCase):
    def test_five_packages_have_complete_policies(self):
        recipes = [json.loads(p.read_text()) for p in Path('packages').glob('*.json') if p.name != 'catalog.json']
        self.assertEqual({r['id'] for r in recipes}, {'vcredist', 'powershell7', 'adobereader', 'chrome', 'edge'})
        for recipe in recipes:
            with self.subTest(package=recipe['id']):
                self.assertTrue(recipe['signer_subjects'])
                self.assertIn('norestart' if recipe['id'] != 'adobereader' else '/rs', recipe['silent_arguments'])
                self.assertFalse(recipe['redistribution_approved'])
                self.assertNotIn('Win32_Product', json.dumps(recipe))
                self.assertTrue(recipe['allowed_hosts'])
                self.assertEqual(len(recipe['supported_os']), 5)

    def test_vendor_allowlist(self):
        recipe = json.loads(Path('packages/chrome.json').read_text())
        resolve.approved('https://dl.google.com/enterprise/chrome.msi', recipe)
        for url in ('http://dl.google.com/install', 'https://dl.google.com.evil.test/install', 'https://secret@dl.google.com/install'):
            with self.assertRaises(ValueError):
                resolve.approved(url, recipe)

    def test_powershell_repository_boundary(self):
        recipe = json.loads(Path('packages/powershell7.json').read_text())
        with self.assertRaises(ValueError):
            resolve.approved('https://github.com/attacker/PowerShell/releases/download/a.exe', recipe)


if __name__ == '__main__':
    unittest.main()
