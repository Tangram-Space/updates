#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Private transport for verified Sparkle tools on an ephemeral macOS runner.

No signing key is generated here. A pre-provisioned Actions secret contains the
canonical Base64 export from Sparkle generate_keys (32-byte seed or old 96-byte
format). Signing uses stdin; the seed is never an argument or a log message.
"""
import base64
from contextlib import contextmanager
import hashlib
import importlib.util
import os
from pathlib import Path
import platform
import secrets
import shlex
import signal
import subprocess
import sys
import tempfile

SECRET_ENV = 'AIRPLAY_SPARKLE_PRIVATE_KEY'
CORE_SHA256 = 'f6a15523085d6e2ca2756a5a1dfe3f4591126c8c72e0dab3cc86169c3bf11dc4'
REPOSITORY = 'Tangram-Space/updates'
FEED_URL = 'https://raw.githubusercontent.com/Tangram-Space/updates/main/feeds/airplay/stable/appcast.xml'


class SigningError(Exception):
    """An error message that is safe to include in public Actions logs."""


class Interrupted(SigningError):
    def __init__(self, number):
        self.number = number
        super().__init__('Signing was interrupted; no publication was requested.')


def require(condition, message):
    if not condition:
        raise SigningError(message)


def runner_root():
    require(sys.platform == 'darwin' and platform.machine() == 'x86_64',
            'Use an Intel macOS runner for this signing operation.')
    require(os.environ.get('GITHUB_ACTIONS') == 'true' and
            os.environ.get('RUNNER_ENVIRONMENT') == 'github-hosted' and
            os.environ.get('GITHUB_REPOSITORY') == REPOSITORY,
            'This helper is restricted to the hosted Actions runner for Tangram-Space/updates.')
    root = Path(os.environ.get('RUNNER_TEMP', '')).resolve(strict=True)
    require(root.is_dir() and bool(os.environ.get('RUNNER_TEMP')),
            'A runner-owned temporary directory is required.')
    return root


def secret_line(value):
    require(isinstance(value, str) and 0 < len(value) <= 256,
            'The Sparkle signing secret is missing or malformed.')
    text = value.strip()
    try:
        decoded = base64.b64decode(text, validate=True)
    except (ValueError, TypeError):
        raise SigningError('The Sparkle signing secret is not canonical Base64.') from None
    require(len(decoded) in (32, 96) and base64.b64encode(decoded).decode('ascii') == text,
            'The Sparkle secret must be a canonical export of 32 or 96 bytes.')
    return text.encode('ascii') + b'\n'


def load_core():
    path = Path(__file__).with_name('release_core.py')
    require(path.is_file() and not path.is_symlink() and
            hashlib.sha256(path.read_bytes()).hexdigest() == CORE_SHA256,
            'The reviewed release-validation core does not match its pinned SHA256.')
    sys.dont_write_bytecode = True
    spec = importlib.util.spec_from_file_location('airplay_release_core', str(path))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class SparkleSigning:
    def __init__(self, value, temporary):
        self._input = secret_line(value)
        self.temporary = temporary
        self.public_key = None
        # Signing subprocesses receive no Actions/GitHub credentials in env.
        self.environment = {key: os.environ[key] for key in
                            ('HOME', 'USER', 'LOGNAME', 'PATH', 'TMPDIR',
                             'LANG', 'LC_ALL', 'DEVELOPER_DIR') if key in os.environ}

    def _execute(self, arguments, input_data=None, capture=False, timeout=900):
        argv = [str(item) for item in arguments]
        name = Path(argv[0]).name
        try:
            result = subprocess.run(argv, input=input_data, stdout=subprocess.PIPE,
                                    stderr=subprocess.PIPE, env=self.environment,
                                    timeout=timeout, check=False)
        except subprocess.TimeoutExpired:
            raise SigningError('The verified ' + name + ' operation timed out.') from None
        except OSError:
            raise SigningError('The verified ' + name + ' tool could not start.') from None
        # Sparkle can echo malformed private input in an error. Never forward
        # either stream, including when a command succeeds unexpectedly.
        require(result.returncode == 0,
                'The verified ' + name + ' operation failed (exit ' + str(result.returncode) + ').')
        if capture:
            try:
                return result.stdout.decode('utf-8').strip()
            except UnicodeError:
                raise SigningError('A verified tool returned an invalid text response.') from None
        return None

    def run(self, arguments, capture=False):
        argv = [str(item) for item in arguments]
        if Path(argv[0]).name in ('generate_appcast', 'sign_update'):
            require(argv[1:3] == ['--account', 'local.chevy.airplay'],
                    'An unexpected signing invocation was refused.')
            argv = [argv[0], '--ed-key-file', '-'] + argv[3:]
            return self._execute(argv, input_data=self._input, capture=capture)
        return self._execute(argv, capture=capture)

    @contextmanager
    def _temporary_keychain(self):
        security = '/usr/bin/security'
        previous_default = shlex.split(self._execute(
            [security, 'default-keychain', '-d', 'user'], capture=True, timeout=60))
        previous_search = shlex.split(self._execute(
            [security, 'list-keychains', '-d', 'user'], capture=True, timeout=60))
        require(len(previous_default) == 1 and bool(previous_search),
                'Could not identify the runner keychain state before changing it.')
        with tempfile.TemporaryDirectory(prefix='airplay-signing-', dir=str(self.temporary)) as raw:
            folder = Path(raw)
            keychain = folder / 'Sparkle-signing.keychain-db'
            password = secrets.token_hex(32)  # Only an ephemeral keychain password.
            try:
                self._execute([security, 'create-keychain', '-p', password, keychain], timeout=60)
                self._execute([security, 'unlock-keychain', '-p', password, keychain], timeout=60)
                self._execute([security, 'default-keychain', '-d', 'user', '-s', keychain], timeout=60)
                self._execute([security, 'list-keychains', '-d', 'user', '-s', keychain], timeout=60)
                yield folder
            finally:
                # Finish restoration even if Actions cancels the current step.
                handlers = {number: signal.signal(number, signal.SIG_IGN)
                            for number in (signal.SIGINT, signal.SIGTERM)}
                cleanup_failed = False
                try:
                    commands = [[security, 'default-keychain', '-d', 'user', '-s', previous_default[0]]]
                    if keychain.exists():
                        commands.append([security, 'delete-keychain', keychain])
                    commands.append([security, 'list-keychains', '-d', 'user', '-s'] + previous_search)
                    for command in commands:
                        try:
                            self._execute(command, timeout=60)
                        except SigningError:
                            cleanup_failed = True
                finally:
                    for number, handler in handlers.items():
                        signal.signal(number, handler)
                require(not cleanup_failed, 'Could not completely restore the temporary runner keychain state.')

    def derive_public_key(self, tools, core):
        # Import + lookup by the SAME official executable avoids a cross-tool
        # Keychain access prompt. Actual archive/feed signing uses stdin instead.
        with self._temporary_keychain() as folder:
            private_file = folder / 'sparkle-import.txt'
            try:
                with private_file.open('xb') as stream:
                    stream.write(self._input[:-1])  # Exact generate_keys -x format: no final newline.
                os.chmod(str(private_file), 0o600)
                self._execute([tools / 'generate_keys', '--account', core.KEYCHAIN_ACCOUNT,
                               '-f', private_file], timeout=120)
            finally:
                if private_file.exists():
                    private_file.unlink()
            value = self._execute([tools / 'generate_keys', '--account', core.KEYCHAIN_ACCOUNT,
                                   '-p'], capture=True, timeout=120)
            self.public_key = core.public_key(value)
        return self.public_key

    def close(self):
        # Do not claim secure erasure of immutable Python bytes or process RAM.
        self._input = b''


def main_guard(action):
    os.umask(0o077)
    value = os.environ.pop(SECRET_ENV, None)
    signing = None
    def interrupt(number, frame):
        raise Interrupted(number)
    old_handler = signal.signal(signal.SIGTERM, interrupt)
    try:
        temporary = runner_root()
        signing = SparkleSigning(value, temporary)
        value = None
        core = load_core()
        core.run = signing.run  # Retain the reviewed validation/release algorithm.
        action(core, signing, temporary)
        return 0
    except Interrupted as error:
        print('ERROR: ' + str(error), file=sys.stderr)
        return 128 + error.number
    except KeyboardInterrupt:
        print('ERROR: Signing was interrupted.', file=sys.stderr)
        return 130
    except (SigningError, ValueError) as error:
        print('ERROR: ' + str(error), file=sys.stderr)
        return 1
    except Exception:
        # No exception traceback or tool output may disclose signing material.
        print('ERROR: Signing preparation failed; no publication was requested.', file=sys.stderr)
        return 1
    finally:
        value = None
        if signing is not None:
            signing.close()
        signal.signal(signal.SIGTERM, old_handler)
