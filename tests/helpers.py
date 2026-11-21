"""Shared helpers for the tests: the shells the scripts run under, stub commands, a scratch directory.

The device scripts run under dash (Ubuntu's /bin/sh), bash and busybox ash (OpenWrt); every shell test runs under
each of them that this machine has (MU300_TEST_SHELLS="dash,busybox sh" picks others). Commands a script calls that
touch the device (nft, ip, id, ...) are replaced by stubs in a directory put first on PATH.
"""
import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

TOP = Path(__file__).resolve().parents[1]
BIN = TOP / 'rootfs' / 'overlay' / 'opt' / 'mu300' / 'bin'
# the tests that read what git tracks (file modes, ls-files) skip where there is no git or no checkout of this tree,
# e.g. a container with the worktree mounted but not the repository it belongs to
GIT_CHECKOUT = bool(shutil.which('git')) and subprocess.run(['git', '-C', str(TOP), 'rev-parse', '--git-dir'],
                                                           capture_output=True).returncode == 0


def _works(argv):
    try:
        return subprocess.run(argv + ['-c', 'true'], capture_output=True, timeout=10).returncode == 0
    except (OSError, subprocess.TimeoutExpired):
        return False


def shells():
    """[argv, ...] of the POSIX shells available here, e.g. [['dash'], ['bash'], ['busybox', 'sh']]."""
    names = os.environ.get('MU300_TEST_SHELLS', 'dash,bash,busybox sh,sh').split(',')
    found, seen = [], set()
    for n in names:
        argv = n.split()
        path = shutil.which(argv[0])
        if not path or not _works(argv):
            continue
        key = (os.path.realpath(path),) + tuple(argv[1:])
        if key not in seen:
            seen.add(key)
            # by its full path: a test that stubs a command of the same name (busybox) must not replace the shell
            found.append([path] + argv[1:])
    return found


class ShellTest(unittest.TestCase):
    """A scratch directory (self.tmp) with a stub directory first on PATH (self.stub)."""

    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix='mu300-test-'))
        self.stubs = self.tmp / 'stubs'
        self.stubs.mkdir()
        self.shells = shells()
        if not self.shells:
            self.skipTest('no POSIX shell')

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def stub(self, name, body):
        """A command NAME that runs BODY (sh); $STUBLOG is the scratch directory, for recording calls."""
        p = self.stubs / name
        p.write_text('#!/bin/sh\n' + body + '\n')
        p.chmod(0o755)

    def env(self, **extra):
        e = dict(os.environ)
        e['PATH'] = f'{self.stubs}{os.pathsep}{e.get("PATH", "")}'
        e['STUBLOG'] = str(self.tmp)
        e['LC_ALL'] = 'C.UTF-8' if os.name != 'nt' else e.get('LC_ALL', '')
        e.update({k: str(v) for k, v in extra.items()})
        return e

    def sh(self, shell, code, stdin=None, **env):
        """Run CODE with SHELL; returns the CompletedProcess (text)."""
        return subprocess.run(shell + ['-c', code], input=stdin, capture_output=True, text=True,
                              env=self.env(**env), timeout=60)

    def script(self, shell, path, *args, stdin=None, **env):
        """Run the script at PATH with SHELL (not its #! line: the point is to try every shell)."""
        return subprocess.run(shell + [str(path)] + [str(a) for a in args], input=stdin, capture_output=True,
                              text=True, env=self.env(**env), timeout=60)

    def each_shell(self):
        # A plain list, not a generator: a generator holding an open subTest context across
        # the yield is closed by GC after the test method returns, when unittest has already
        # cleared _outcome, so subTest.__exit__ crashes on Python 3.12+ (AttributeError) and
        # storms on 3.13+ (RuntimeError: generator ignored GeneratorExit).
        return self.shells

    def stub_wins(self, shell, name):
        """True when 'command -v NAME' under SHELL resolves to the stub of NAME. A busybox ash whose
        busybox has NAME as an applet runs the builtin instead of the PATH stub: the call then happens
        for real, can neither be observed in the log nor made to fail, and a builtin that succeeds also
        keeps a script from reaching its fallback. The call sequence is the same script logic in every
        shell, so tests that watch a command skip the shells where the stub cannot win."""
        r = subprocess.run(shell + ['-c', f'command -v {name}'], capture_output=True, text=True,
                           env=self.env(), timeout=10)
        return r.stdout.strip() == str(self.stubs / name)

    def observable_shells(self, name):
        """self.shells filtered by stub_wins(); the stub of NAME must exist when this is called."""
        return [s for s in self.shells if self.stub_wins(s, name)]
