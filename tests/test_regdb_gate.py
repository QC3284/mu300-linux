'''The regulatory database gate: an image may only ship a database whose signature verifies.

v2026.11.08.5 carried the 2026.09.03 database under the 2026.05.30 signature. The kernel is built with
CONFIG_CFG80211_REQUIRE_SIGNED_REGDB=y, rejected the pair, fell back to the world regdomain and hostapd disabled
the 5 GHz AP (ch36 NO-IR).
'''
import hashlib
import io
import shutil
import subprocess
import tarfile
import tempfile
import unittest
from pathlib import Path

from helpers import TOP

GATE = TOP / 'tools' / 'check-regdb.sh'
PAIR = TOP / 'rootfs' / 'overlay' / 'lib' / 'firmware'
DB = PAIR / 'regulatory.db'
P7S = PAIR / 'regulatory.db.p7s'
# the pair is the wireless-regdb 2026.09.03 release, signed by CN=wens (sources.openwrt.org tarball
# b22e0901227b820cd1c280abe681a15b773a5103a5e10dc442e94ebb34cbf58d)
DB_SHA = '7e236caecd939c8ec98be4870bf30422f28ffef2565a38aaaa2d9ddabd0c2641'
P7S_SHA = '50332f0db09b8bcc719235ec4985c27377f2cc2f42abb7b5dcf951866c5a888a'


def image(path, members):
    '''Write a tarball with MEMBERS ({archive name: bytes}); the name is stored as given.'''
    with tarfile.open(path, 'w:gz') as t:
        for name, data in members.items():
            info = tarfile.TarInfo(name)
            info.size = len(data)
            info.mode = 0o644
            t.addfile(info, io.BytesIO(data))
    return path


class Gate(unittest.TestCase):
    '''tools/check-regdb.sh reads the pair out of an image and verifies the signature; the layout ships the pair
    from the tree and the update audit calls the gate, so a release whose pair does not verify fails its build.
    '''

    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix='mu300-regdb-'))
        self.addCleanup(shutil.rmtree, self.tmp, True)

    def gate(self, path):
        return subprocess.run(['sh', str(GATE), str(path)], capture_output=True, text=True, timeout=120)

    def test_the_shipped_pair_is_the_reviewed_one(self):
        self.assertEqual(hashlib.sha256(DB.read_bytes()).hexdigest(), DB_SHA)
        self.assertEqual(hashlib.sha256(P7S.read_bytes()).hexdigest(), P7S_SHA)

    def test_the_pair_verifies(self):
        img = image(self.tmp / 'good.tar.gz', {
            './lib/firmware/regulatory.db': DB.read_bytes(),
            './lib/firmware/regulatory.db.p7s': P7S.read_bytes(),
        })
        p = self.gate(img)
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertIn('signature verifies', p.stdout)

    def test_the_pair_is_found_without_the_dot_prefix_too(self):
        img = image(self.tmp / 'plain.tar.gz', {
            'lib/firmware/regulatory.db': DB.read_bytes(),
            'lib/firmware/regulatory.db.p7s': P7S.read_bytes(),
        })
        self.assertEqual(self.gate(img).returncode, 0)

    def test_a_database_that_does_not_match_its_signature_is_refused(self):
        data = bytearray(DB.read_bytes())
        data[len(data) // 2] ^= 0xff
        img = image(self.tmp / 'mixed.tar.gz', {
            './lib/firmware/regulatory.db': bytes(data),
            './lib/firmware/regulatory.db.p7s': P7S.read_bytes(),
        })
        p = self.gate(img)
        self.assertNotEqual(p.returncode, 0)
        self.assertIn('does not match its signature', p.stderr)

    def test_a_database_without_its_signature_is_refused(self):
        img = image(self.tmp / 'db.tar.gz', {'./lib/firmware/regulatory.db': DB.read_bytes()})
        p = self.gate(img)
        self.assertNotEqual(p.returncode, 0)
        self.assertIn('without its signature', p.stderr)

    def test_a_signature_without_its_database_is_refused(self):
        img = image(self.tmp / 'p7s.tar.gz', {'./lib/firmware/regulatory.db.p7s': P7S.read_bytes()})
        p = self.gate(img)
        self.assertNotEqual(p.returncode, 0)
        self.assertIn('no regulatory.db', p.stderr)

    def test_an_image_with_no_database_is_not_failed(self):
        img = image(self.tmp / 'none.tar.gz', {'./etc/x': b'x'})
        p = self.gate(img)
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertIn('no regulatory database', p.stdout)

    def test_the_layout_ships_the_pair_and_the_audit_checks_it(self):
        layout = (TOP / 'tools' / 'make-release-layout.sh').read_text()
        self.assertIn('rootfs/overlay/$_rf', layout)
        self.assertIn('lib/firmware/regulatory.db.p7s', layout)
        audit = (TOP / 'tools' / 'check-update-audit.sh').read_text()
        self.assertIn('check-regdb.sh', audit)


if __name__ == '__main__':
    unittest.main()
