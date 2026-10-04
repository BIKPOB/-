"""Publish matching, successful Android/Windows CI artifacts as a prerelease."""
from pathlib import Path
import base64, hashlib, json, os, re, subprocess, time, zipfile
REPO = os.environ['GITHUB_REPOSITORY']
SHA = os.environ['RELEASE_SHA']
assert re.fullmatch(r'[a-f0-9]{40}', SHA)
def gh(*args):
    return subprocess.check_output(['gh', *args], text=True)
def api(path): return json.loads(gh('api', path))
workflows = {'Build Android APK': None, 'Windows build and security audit': None}
for attempt in range(120):
    runs = api(f'repos/{REPO}/actions/runs?head_sha={SHA}&event=push&per_page=100')['workflow_runs']
    for name in workflows:
        found = [r for r in runs if r['name'] == name and r['head_branch'] == 'main']
        if found:
            workflows[name] = max(found, key=lambda r: r['id'])
    if all(workflows.values()):
        failed = [r for r in workflows.values() if r['status'] == 'completed' and r['conclusion'] != 'success']
        if failed: raise SystemExit('Build/audit did not succeed; release is blocked')
        if all(r['status'] == 'completed' and r['conclusion'] == 'success' for r in workflows.values()): break
    time.sleep(15)
else: raise SystemExit('Matching successful builds were not ready in time')
source = api(f'repos/{REPO}/contents/pubspec.yaml?ref={SHA}')
text = base64.b64decode(source['content']).decode()
version = re.search(r'^version:\s*(\d+\.\d+\.\d+)\+\d+\s*$', text, re.M).group(1)
tag = 'v' + version
existing = subprocess.run(['gh', 'release', 'view', tag, '-R', REPO, '--json', 'targetCommitish,isDraft,url'], text=True, capture_output=True)
if existing.returncode == 0:
    release = json.loads(existing.stdout)
    assert release['targetCommitish'] == SHA, 'Version already belongs to a different source commit'
    assert not release['isDraft'], 'A draft already exists; inspect before changing it'
    print('Already published:', release['url']); raise SystemExit(0)
root = Path('release-payload'); root.mkdir()
android = root/'android'; windows = root/'windows'; audit = root/'windows-audit'
for run_name, artifact, target in [
    ('Build Android APK', 'quiet-vpn-android-apk', android),
    ('Windows build and security audit', 'quiet-vpn-windows-x64', windows),
    ('Windows build and security audit', 'windows-security-report', audit)]:
    gh('run', 'download', str(workflows[run_name]['id']), '-R', REPO, '-n', artifact, '-D', str(target))
for directory in [android, windows]:
    assert (directory/'SOURCE_COMMIT.txt').read_text(encoding='utf-8-sig').strip() == SHA
    for line in (directory/'SHA256SUMS.txt').read_text(encoding='utf-8-sig').splitlines():
        expected, name = line.split(maxsplit=1)
        name = name.strip().replace('\\', '/')
        if directory == android: name = Path(name).name
        file = (directory/name).resolve()
        assert file.is_relative_to(directory.resolve()), 'Unsafe artifact path'
        assert hashlib.sha256(file.read_bytes()).hexdigest() == expected.lower(), 'Artifact checksum mismatch'
for report in [android/'ANTIVIRUS_SCAN.txt', audit/'windows-clamav.txt']:
    assert re.search(r'Infected files:\s*0\s*$', report.read_text(), re.M), 'No clean antivirus report'
out = root/'assets'; out.mkdir()
apk = out/f'quiet-vpn-android-{version}.apk'; apk.write_bytes((android/'quiet-vpn-android.apk').read_bytes())
with zipfile.ZipFile(out/f'quiet-vpn-windows-x64-{version}.zip', 'w', zipfile.ZIP_DEFLATED) as archive:
    for file in sorted(windows.rglob('*')):
        if file.is_file(): archive.write(file, file.relative_to(windows))
with zipfile.ZipFile(out/f'quiet-vpn-{version}-audit.zip', 'w', zipfile.ZIP_DEFLATED) as archive:
    for file in sorted(android.iterdir()):
        if file.suffix in {'.txt', '.json'}: archive.write(file, 'android/'+file.name)
    for file in sorted(audit.rglob('*')):
        if file.is_file(): archive.write(file, 'windows/'+str(file.relative_to(audit)))
files = sorted(out.iterdir())
checksums = out/'SHA256SUMS.txt'
checksums.write_text(''.join(hashlib.sha256(f.read_bytes()).hexdigest()+'  '+f.name+'\n' for f in files))
files.append(checksums)
notes = root/'notes.md'
notes.write_text(f'''Тестовая сборка Quiet VPN {version}, Android и Windows x64.

- Исходный коммит: `{SHA}`.
- Android APK: Android 8+, ARM64/ARMv7. Подпись тестовая; обновление поверх прежнего APK может быть несовместимо по подписи. Перед удалением приложения сохраните свои конфигурации.
- Windows: распакуйте весь ZIP и следуйте INSTALL.txt. OpenVPN и драйвер устанавливаются отдельно через приложение. EXE не подписан издательским сертификатом.
- APK и Windows-комплект прошли автоматические тесты и аудит CI. Отчёты и контрольные суммы приложены.
- Сборка остаётся экспериментальной: были сообщения о вылетах при подключении. Отсутствие сбоев на вашем устройстве и DNS/IPv6-утечек не подтверждено. В Android доступна кнопка «Диагностика сбоя».
- Автоматического каталога WireGuard/AmneziaWG нет; нужны действующие конфигурации серверов.

[Android CI]({workflows['Build Android APK']['html_url']}) · [Windows CI]({workflows['Windows build and security audit']['html_url']})
''')
gh('release', 'create', tag, *map(str, files), '-R', REPO, '--target', SHA,
   '--title', f'Quiet VPN {version} — test build', '--notes-file', str(notes), '--prerelease', '--draft')
gh('release', 'edit', tag, '-R', REPO, '--draft=false')
print(f'Published https://github.com/{REPO}/releases/tag/{tag}')
