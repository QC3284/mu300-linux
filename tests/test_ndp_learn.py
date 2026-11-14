"""ndp-learn's RA self-heal: re-solicit when the bearer has no global address or no RA default route."""
import unittest

from helpers import BIN, ShellTest


class RaCheck(ShellTest):
    """--ra-check flips accept_ra 0 -> 2 only when the RA did not land: the bearer needs both its global address
    and the default route the RA installs. The flip is visible through the sleep: accept_ra is 0 while it waits."""

    GLOBAL = 'inet6 2001:db8:1:2::3/64 scope global dynamic mngtmpaddr noprefixroute\n'
    LINK = 'inet6 fe80::1/64 scope link\n'
    RA_ROUTE = 'default via fe80::1 dev sipa_eth0 proto ra metric 1024 expires 1799sec hoplimit 64\n'
    STATIC_ROUTE = 'default via fe80::1 dev sipa_eth0 proto static metric 1024\n'

    def setUp(self):
        super().setUp()
        self.stub('ip', '\n'.join([
            'echo "$@" >> "$STUBLOG/ip.log"',
            'case "$*" in',
            '    "-6 addr show sipa_eth0") cat "$STUBLOG/addr" ;;',
            '    "-6 route show dev sipa_eth0") cat "$STUBLOG/routes" ;;',
            'esac',
            'exit 0',
        ]))
        self.proc = self.tmp / 'proc'
        self.conf = self.proc / 'net' / 'ipv6' / 'conf' / 'sipa_eth0'
        self.conf.mkdir(parents=True)
        text = (BIN / 'ndp-learn').read_text().replace('/proc/sys', str(self.proc))
        text = text.replace('    sleep 1' + chr(10),
                              '    echo "wait $(cat "$STUBLOG/proc/net/ipv6/conf/sipa_eth0/accept_ra")" >> "$STUBLOG/waits"' + chr(10))
        self.script_path = self.tmp / 'ndp-learn'
        self.script_path.write_text(text)
        self.addr = self.tmp / 'addr'
        self.routes = self.tmp / 'routes'

    def ra_shells(self):
        # busybox sh runs its own applets before PATH, so a stubbed `ip` would not be the one ra_check asks;
        # on the device that applet is the same ip. The other shells exercise the logic.
        for shell in self.each_shell():
            if shell[0].endswith('busybox'):
                continue
            yield shell

    def check(self, shell, addr, routes):
        self.addr.write_text(addr)
        self.routes.write_text(routes)
        (self.conf / 'accept_ra').write_text('2\n')
        for p in (self.tmp / 'waits', self.tmp / 'ip.log'):
            p.unlink(missing_ok=True)
        r = self.script(shell, self.script_path, '--ra-check')
        self.assertEqual(r.returncode, 0, r.stderr)
        waited = (self.tmp / 'waits').read_text().strip() if (self.tmp / 'waits').exists() else ''
        return (self.conf / 'accept_ra').read_text().strip(), waited

    def test_a_bearer_that_took_its_ra_is_left_alone(self):
        for shell in self.ra_shells():
            value, waited = self.check(shell, self.GLOBAL, self.RA_ROUTE)
            self.assertEqual(value, '2')
            self.assertEqual(waited, '')

    def test_a_lost_default_route_is_re_solicited(self):
        for shell in self.ra_shells():
            value, waited = self.check(shell, self.GLOBAL, self.STATIC_ROUTE)
            self.assertEqual(value, '2')
            self.assertEqual(waited, 'wait 0')

    def test_a_missing_address_is_re_solicited(self):
        for shell in self.ra_shells():
            value, waited = self.check(shell, self.LINK, self.RA_ROUTE)
            self.assertEqual(value, '2')
            self.assertEqual(waited, 'wait 0')

    def test_nothing_at_all_is_re_solicited(self):
        for shell in self.ra_shells():
            value, waited = self.check(shell, self.LINK, '')
            self.assertEqual(value, '2')
            self.assertEqual(waited, 'wait 0')


class Source(unittest.TestCase):
    """The forwarding switch resets accept_ra to 0 on the bearer; mobile-data re-arms it right after."""

    def test_the_forwarding_switch_does_not_leave_accept_ra_off(self):
        text = (BIN / 'mobile-data').read_text()
        i = text.index('sysctl -qw net.ipv6.conf.all.forwarding=1')
        j = text.index('echo 2 > "$c/accept_ra"', i)
        self.assertLess(j - i, 400, 'the re-arm must follow the forwarding switch directly')

    def test_the_loop_keeps_re_soliciting(self):
        text = (BIN / 'ndp-learn').read_text()
        loop = text[text.index('while :; do'):]
        self.assertIn('ra_check', loop)
        self.assertIn('--ra-check', text)


if __name__ == '__main__':
    unittest.main()
