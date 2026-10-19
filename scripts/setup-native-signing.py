#!/usr/bin/env python3
"""Create one persistent, private local development signing identity for Flow.

Re-running reuses the identity. No TCC resets, system trust changes or Apple
account are required. Local certificate trust is constrained to code signing
and requires --trust-local-certificate. Does not replace the application.
"""
import argparse
import json
import os
from pathlib import Path
import secrets
import shlex
import subprocess
import tempfile

from native_signing import DEFAULT_CONFIG, SigningIdentity, command, designated_requirement, satisfies


def private_write(path, contents):
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(descriptor, 'w') as output:
        output.write(contents)


def create_identity(config):
    folder = config.parent
    folder.mkdir(parents=True, mode=0o700, exist_ok=True)
    if folder.stat().st_uid != os.getuid() or folder.stat().st_mode & 0o077:
        raise RuntimeError('The Flow signing directory must belong to you and have mode 0700.')
    keychain = folder / 'flow-development.keychain-db'
    password_file = folder / 'keychain-password'
    certificate = folder / 'certificate.pem'
    if any(path.exists() for path in [keychain, password_file, certificate]):
        raise RuntimeError('A partial signing setup exists. Preserve it and recover its identity instead of replacing the certificate.')
    password = secrets.token_urlsafe(40)
    private_write(password_file, password + '\n')
    original_search_list = shlex.split(command(['security', 'list-keychains', '-d', 'user']).stdout)
    try:
        command(['security', 'create-keychain', '-p', password, str(keychain)])
        os.chmod(keychain, 0o600)
        command(['security', 'set-keychain-settings', '-lut', '21600', str(keychain)])
        command(['security', 'unlock-keychain', '-p', password, str(keychain)])
        with tempfile.TemporaryDirectory(prefix='flow-signing-') as temp:
            scratch = Path(temp)
            extensions = scratch / 'certificate.cnf'
            extensions.write_text('[req]\nprompt=no\ndistinguished_name=subject\nx509_extensions=signing\n'
                                  '[subject]\nCN=Flow Local Development\nO=Flow Local Development\n'
                                  '[signing]\nbasicConstraints=critical,CA:FALSE\n'
                                  'keyUsage=critical,digitalSignature\nextendedKeyUsage=critical,codeSigning\n'
                                  'subjectKeyIdentifier=hash\n')
            key = scratch / 'private-key.pem'
            archive = scratch / 'identity.p12'
            command(['openssl', 'req', '-new', '-newkey', 'rsa:3072', '-nodes', '-x509', '-sha256',
                     '-days', '3650', '-config', str(extensions), '-keyout', str(key), '-out', str(certificate)])
            os.chmod(certificate, 0o600)
            # PKCS#12 compatibility with macOS Security.framework, without using
            # the OpenSSL legacy provider or persisting the exported private key.
            environment = {**os.environ, 'FLOW_P12_PASSWORD': password}
            result = subprocess.run(['openssl', 'pkcs12', '-export', '-inkey', str(key), '-in', str(certificate),
                                     '-name', 'Flow Local Development', '-out', str(archive),
                                     '-keypbe', 'PBE-SHA1-3DES', '-certpbe', 'PBE-SHA1-3DES', '-macalg', 'sha1',
                                     '-passout', 'env:FLOW_P12_PASSWORD'], env=environment, capture_output=True, text=True)
            if result.returncode:
                raise RuntimeError('Could not package the local signing identity: ' + result.stderr.strip())
            command(['security', 'import', str(archive), '-k', str(keychain), '-f', 'pkcs12',
                     '-P', password, '-x', '-T', '/usr/bin/codesign'])
        command(['security', 'set-key-partition-list', '-S', 'apple-tool:', '-s', '-k', password, str(keychain)])
        fingerprint = command(['openssl', 'x509', '-in', str(certificate), '-noout', '-fingerprint', '-sha1']).stdout.split('=', 1)[-1].strip().replace(':', '').upper()
        private_write(config, json.dumps({'version': 1, 'fingerprint': fingerprint, 'keychain': str(keychain),
                                         'certificate': str(certificate), 'password_file': str(password_file)}, indent=2) + '\n')
    finally:
        # Creating a keychain can add it to the user's search list. Codesign
        # addresses ours explicitly; keep the user's normal search list intact.
        current = shlex.split(command(['security', 'list-keychains', '-d', 'user']).stdout)
        if current != original_search_list:
            command(['security', 'list-keychains', '-d', 'user', '-s', *original_search_list])


def verify_updates(identity):
    """Different real Mach-O programs must authenticate as the same app."""
    with tempfile.TemporaryDirectory(prefix='flow-signing-check-') as temp:
        folder = Path(temp)
        versions = []
        for version in [1, 2]:
            source = folder / f'probe-{version}.c'
            executable = folder / f'probe-{version}'
            source.write_text(f'int main(void) {{ return {version}; }}\n')
            command(['clang', str(source), '-o', str(executable)])
            identity.sign(executable, 'com.flow.signing-probe')
            versions.append(executable)
        first, second = versions
        if first.read_bytes() == second.read_bytes():
            raise RuntimeError('Signing probes must contain different code.')
        if not satisfies(second, designated_requirement(first)) or not satisfies(first, designated_requirement(second)):
            raise RuntimeError('The signing identity does not authenticate updates consistently.')
        identity.check_upgrade(first, second)
        # A program using the same identifier but another key must not pass.
        command(['codesign', '--force', '--sign', '-', '--identifier', 'com.flow.signing-probe', str(second)])
        if satisfies(second, designated_requirement(first)):
            raise RuntimeError('The signing requirement accepted an unrelated signer.')
        for migration in [False, True]:
            try:
                identity.check_upgrade(first, second, migrate=migration)
            except RuntimeError:
                pass
            else:
                raise RuntimeError('The update guard accepted a replacement with another signer.')
        try:
            identity.check_upgrade(second, first)
        except RuntimeError:
            pass
        else:
            raise RuntimeError('Ad-hoc migration must be explicit.')
        identity.check_upgrade(second, first, migrate=True)
        before = command(['security', 'list-keychains', '-d', 'user']).stdout
        try:
            identity.sign(folder / 'missing-program', 'com.flow.signing-probe')
        except RuntimeError:
            pass
        else:
            raise RuntimeError('Signing a missing program unexpectedly succeeded.')
        if command(['security', 'list-keychains', '-d', 'user']).stdout != before:
            raise RuntimeError('A failed signing attempt changed the keychain search list.')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--config', type=Path, default=DEFAULT_CONFIG)
    parser.add_argument('--trust-local-certificate', action='store_true',
                        help='Trust this certificate for code signing in your user domain only (macOS may request authentication once)')
    args = parser.parse_args()
    config = args.config.expanduser().resolve()
    if not config.exists():
        create_identity(config)
        print('Created a persistent local signing identity in a private Flow keychain.')
    else:
        print('Reusing the existing Flow signing identity.')
    identity = SigningIdentity(config)
    if args.trust_local_certificate:
        command(['security', 'add-trusted-cert', '-r', 'trustRoot', '-p', 'codeSign',
                 '-k', str(identity.keychain), str(identity.certificate)])
    verify_updates(identity)
    print('Verified: different builds satisfy the same certificate-backed identity; an unrelated signer is rejected.')
    print('No application or privacy grants were changed.')


if __name__ == '__main__':
    try:
        main()
    except (RuntimeError, OSError, ValueError, KeyError) as error:
        raise SystemExit(str(error))
