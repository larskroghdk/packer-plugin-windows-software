"""Resolve stable versions from Microsoft's winget index, then download only approved vendor URLs.

Index checksums are independent expectations; Windows Authenticode validation is a separate step.
No software is executed by this script. Publication is handled only after Windows validation.
"""
import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import re
import urllib.request
from urllib.parse import urlparse
import yaml


def request(url):
    headers = {'User-Agent': 'packer-plugin-windows-software'}
    # Never send GitHub credentials to vendors or redirect targets.
    if urlparse(url).hostname == 'api.github.com' and os.getenv('GH_TOKEN'):
        headers['Authorization'] = 'Bearer ' + os.environ['GH_TOKEN']
    with urllib.request.urlopen(urllib.request.Request(url, headers=headers), timeout=120) as response:
        return response.read()


def approved(url, recipe):
    parsed = urlparse(url)
    if parsed.scheme != 'https' or parsed.username or parsed.password or parsed.hostname not in recipe['allowed_hosts']:
        raise ValueError('Unapproved vendor URL: ' + url)
    if recipe['id'] == 'powershell7' and not parsed.path.startswith('/PowerShell/PowerShell/releases/download/'):
        raise ValueError('PowerShell download must come from the official repository')


def matching_installers(recipe, manifest):
    """Select only the package format the engine actually knows how to execute."""
    candidates = []
    for candidate in manifest['Installers']:
        effective = {**manifest, **candidate}
        kind = effective.get('InstallerType')
        if effective.get('Architecture') == 'x64' and kind in ({'msi','wix'} if recipe['installer_type']=='msi' else {'exe','burn','inno','nullsoft'}):
            if effective.get('Scope', 'machine') == 'machine' and effective.get('InstallerLocale', 'en-US') in ('en-US','en-us'):
                candidates.append(effective)
    return candidates


def find_installer(recipe):
    """Find the newest stable version with a compatible installer, skipping MSIX-only releases."""
    package = recipe['winget']
    root = 'https://api.github.com/repos/microsoft/winget-pkgs/contents/manifests/' + package[0].lower() + '/' + package.replace('.', '/')
    entries = json.loads(request(root))
    versions = sorted((e for e in entries if e['type'] == 'dir' and re.fullmatch(r'\d+(?:\.\d+){1,3}', e['name'])),
                      key=lambda e: tuple(int(x) for x in e['name'].split('.')), reverse=True)
    for entry in versions:
        # Read immutable tree/blob objects, not a branch that may move during validation.
        files = json.loads(request(entry['git_url']))['tree']
        installer = next(e for e in files if e['path'].endswith('.installer.yaml'))
        blob = json.loads(request(installer['url']))
        manifest = yaml.safe_load(base64.b64decode(blob['content']))
        candidates = matching_installers(recipe, manifest)
        if candidates:
            return entry['name'], candidates[0]
        print(f"{package} {entry['name']}: no compatible {recipe['installer_type']} installer; checking previous stable version", flush=True)
    raise ValueError('No matching x64 machine installer for ' + package)


def resolve(recipe, output):
    version, candidate = find_installer(recipe)
    url = candidate['InstallerUrl']
    approved(url, recipe)
    filename = f"{recipe['id']}-x64-{version}.{recipe['installer_type']}"
    destination = output / filename
    # Stream instead of buffering large installers. Reject insecure redirects.
    class SecureRedirect(urllib.request.HTTPRedirectHandler):
        def redirect_request(self, req, fp, code, msg, headers, newurl):
            if urlparse(newurl).scheme != 'https':
                raise ValueError('Insecure vendor redirect')
            # GitHub signed asset endpoints differ from github.com; HTTPS remains mandatory.
            return super().redirect_request(req, fp, code, msg, headers, newurl)
    digest = hashlib.sha256()
    with urllib.request.build_opener(SecureRedirect).open(url, timeout=120) as source, destination.open('wb') as target:
        size = 0
        while chunk := source.read(1024*1024):
            size += len(chunk)
            if size > 2*1024**3:
                raise ValueError('Installer exceeds 2 GiB')
            digest.update(chunk)
            target.write(chunk)
    if digest.hexdigest().lower() != candidate['InstallerSha256'].lower():
        destination.unlink()
        raise ValueError('Upstream checksum mismatch for ' + package)
    record = {k:v for k,v in recipe.items() if k not in ('winget','allowed_hosts','redistribution_approved')}
    record.update(version=version, url=url, official_url=url, source='vendor', sha256=digest.hexdigest(), validated_at='')
    (output / (recipe['id']+'.candidate.json')).write_text(json.dumps(record, indent=2)+'\n')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', default='artifacts')
    parser.add_argument('--package', default='all')
    args = parser.parse_args()
    output = Path(args.output)
    output.mkdir(parents=True, exist_ok=True)
    recipes = [json.loads(p.read_text()) for p in sorted(Path('packages').glob('*.json')) if p.name != 'catalog.json']
    selected = [r for r in recipes if args.package == 'all' or r['id'] == args.package]
    if not selected:
        parser.error('Unknown package')
    for recipe in selected:
        resolve(recipe, output)


if __name__ == '__main__':
    main()
