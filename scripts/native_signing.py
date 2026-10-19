"""Persistent, certificate-backed signing for this Mac's native Flow builds.

The dedicated keychain and its generated password live outside the repository.
Never silently fall back to ad-hoc signing: that loses macOS privacy grants.
"""
import json
import fcntl
import os
from pathlib import Path
import re
import shlex
import subprocess

SIGNING_DIRECTORY = Path.home() / 'Library/Application Support/Flow/Signing'
DEFAULT_CONFIG = SIGNING_DIRECTORY / 'identity.json'


def command(arguments):
    # Arguments can contain the password of our dedicated development keychain.
    # Do not include argv in exceptions, logs or CalledProcessError tracebacks.
    result = subprocess.run(arguments, capture_output=True, text=True)
    if result.returncode:
        raise RuntimeError(f'{Path(arguments[0]).name} failed: {result.stderr.strip()}')
    return result


def designated_requirement(path):
    result = command(['codesign', '--display', '-r-', str(path)])
    match = re.search(r'(?:^|\n)#?\s*designated => (.+)', result.stdout + '\n' + result.stderr)
    if not match:
        raise RuntimeError('The app has no designated signing requirement.')
    return match.group(1).strip()


def satisfies(path, requirement):
    return subprocess.run(['codesign', '--verify', '--strict', '-R', '=' + requirement, str(path)],
                          stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode == 0


class SigningIdentity:
    def __init__(self, config=DEFAULT_CONFIG):
        self.config = Path(config).expanduser().resolve()
        if not self.config.is_file():
            raise RuntimeError('Persistent Flow signing is not set up. Run python3 scripts/setup-native-signing.py once. No app was replaced.')
        data = json.loads(self.config.read_text())
        self.fingerprint = data['fingerprint'].upper()
        if not re.fullmatch(r'[0-9A-F]{40}', self.fingerprint):
            raise RuntimeError('Invalid signing certificate fingerprint.')
        self.keychain = Path(data['keychain'])
        self.certificate = Path(data['certificate'])
        self.password_file = Path(data['password_file'])
        for path in [self.config, self.keychain, self.certificate, self.password_file]:
            if not path.is_file() or path.is_symlink() or path.stat().st_uid != os.getuid():
                raise RuntimeError('Flow signing files must exist and belong to the current user.')
        if self.password_file.stat().st_mode & 0o077:
            raise RuntimeError('The signing keychain password file must have mode 0600.')
        actual = command(['openssl', 'x509', '-in', str(self.certificate), '-noout', '-fingerprint', '-sha1']).stdout
        if actual.split('=', 1)[-1].strip().replace(':', '').upper() != self.fingerprint:
            raise RuntimeError('The configured certificate fingerprint changed. Restore the original identity; do not generate another one.')

    def unlock(self):
        command(['security', 'unlock-keychain', '-p', self.password_file.read_text().strip(), str(self.keychain)])

    def requirement(self, identifier):
        # A certificate pin authenticates updates. An identifier-only or cdhash
        # requirement would respectively be too weak or change with each build.
        if not re.fullmatch(r'[A-Za-z0-9._-]+', identifier):
            raise RuntimeError('Invalid signing identifier.')
        return f'identifier "{identifier}" and certificate leaf = H"{self.fingerprint}"'

    def sign(self, path, identifier):
        self.unlock()
        # macOS requires the keychain on the search list even with --keychain.
        # Add it only while signing; preserve unrelated user changes afterward.
        descriptor = os.open(self.config.parent / 'signing.lock', os.O_CREAT | os.O_RDWR, 0o600)
        with os.fdopen(descriptor, 'w') as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            original = shlex.split(command(['security', 'list-keychains', '-d', 'user']).stdout)
            def ours(value):
                return Path(value).exists() and Path(value).samefile(self.keychain)
            added = not any(ours(p) for p in original)
            try:
                if added:
                    command(['security', 'list-keychains', '-d', 'user', '-s', *original, str(self.keychain)])
                command(['codesign', '--force', '--sign', self.fingerprint,
                         '--keychain', str(self.keychain), '--timestamp=none',
                         '--identifier', identifier, '--requirements', '=designated => ' + self.requirement(identifier), str(path)])
            finally:
                if added:
                    current = shlex.split(command(['security', 'list-keychains', '-d', 'user']).stdout)
                    command(['security', 'list-keychains', '-d', 'user', '-s', *[p for p in current if not ours(p)]])
        command(['codesign', '--verify', '--strict', '-R', '=' + self.requirement(identifier), str(path)])

    def sign_bundle(self, app):
        helper = Path(app) / 'Contents/Helpers/FlowHelper'
        if helper.exists():
            self.sign(helper, 'com.flow.flow.helper')
        self.sign(app, 'com.flow.flow')
        command(['codesign', '--verify', '--deep', '--strict', str(app)])

    def check_upgrade(self, old_app, new_app, migrate=False):
        if not Path(old_app).exists():
            return
        old_requirement = designated_requirement(old_app)
        details = command(['codesign', '--display', '--verbose=2', str(old_app)])
        if 'Signature=adhoc' in details.stderr:
            if migrate:
                return  # Explicit, one-time migration from the old temporary signer.
            raise RuntimeError('The installed app is ad-hoc signed. Use --migrate-signing once to adopt the persistent identity.')
        if not satisfies(new_app, old_requirement) or not satisfies(old_app, designated_requirement(new_app)):
            raise RuntimeError('This update changes Flow’s signing identity. Installation stopped to preserve privacy grants. Restore the original signing configuration.')

