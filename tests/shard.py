"""The test modules of one CI shard: python3 shard.py N I prints the test_*.py module names (no .py) that shard I
of N runs. The modules are packed by measured cost (WEIGHTS, seconds of wall time on a runner, from the 2026-11-15
sharded run) so the four jobs finish together instead of one shard carrying the whole suite: greedy longest-first is
within a few percent of the best packing, and it does not need a hand-kept HEAVY list."""
import sys
from pathlib import Path

# Seconds per module, measured on ubuntu-24.04 (Python 3.12), one number per test module. A module not listed here is
# assumed to be a small one; add it when it grows.
WEIGHTS = {
    'test_adb': 62.7,
    'test_all_modules': 10.7,
    'test_android_boot_image': 2.4,
    'test_android_install': 294.3,
    'test_android_mount': 0.0,
    'test_android_web': 42.0,
    'test_answers': 200.5,
    'test_api': 85.5,
    'test_atd_dash': 0.0,
    'test_backup': 630.2,
    'test_boot_image': 1.4,
    'test_boot_init': 4.0,
    'test_bootchain': 280.3,
    'test_carry': 27.3,
    'test_cpu': 1.8,
    'test_cpu_voltage': 2.4,
    'test_dashboard_info': 276.6,
    'test_dashboard_power': 241.6,
    'test_delta': 555.6,
    'test_device_scripts': 1139.6,
    'test_early_dhcp': 86.2,
    'test_early_replay_hook': 0.0,
    'test_emmc_lookup': 1.1,
    'test_extra': 544.4,
    'test_fgu_shutdown': 0,
    'test_gui': 22.3,
    'test_gui_launch': 0.8,
    'test_i18n': 10.9,
    'test_installer': 8.8,
    'test_kernel_bundle_audit': 0.0,
    'test_kernel_src_signature': 0.3,
    'test_luci_i18n': 685.3,
    'test_magisk_installer': 70.0,
    'test_magisk_switch': 6.5,
    'test_magisk_zip': 50.4,
    'test_mu300_thermal': 0.5,
    'test_mu300cell': 205.5,
    'test_mu300dash_security': 226.2,
    'test_mu300vpn': 386.6,
    'test_ndp_learn': 0.0,
    'test_package': 11.1,
    'test_panel': 57.1,
    'test_panel_resilience': 171.8,
    'test_po2lmo': 0.1,
    'test_power': 787.4,
    'test_regdb_gate': 0.1,
    'test_releases': 1.1,
    'test_resize_last_partition': 0.2,
    'test_resume': 153.7,
    'test_sdhci_order': 0.0,
    'test_sim2': 9.9,
    'test_sim_hot': 134.0,
    'test_sim_selection': 204.3,
    'test_sipa_eth_xmit': 0.0,
    'test_smoke': 0.0,
    'test_sms_forward': 73.9,
    'test_sms_pool': 719.3,
    'test_static': 202.2,
    'test_terminal': 1.6,
    'test_traffic': 21.8,
    'test_ttl': 1.2,
    'test_uhttpd_key': 0.3,
    'test_unisoc_plugin': 37.2,
    'test_update': 334.9,
    'test_update_page': 152.5,
    'test_usb_management': 7.4,
    'test_usb_pd': 0.0,
    'test_user_packages': 36.7,
    'test_vendor_ids': 92.5,
    'test_voice_audio': 0.1,
    'test_vpn_hooks': 199.0,
    'test_web_installer': 9.8,
    'test_wifi': 90.2,
    'test_wifi_channels': 2.4,
    'test_wifi_client': 191.0,
    'test_wifi_tx_path': 0.0,
    'test_wpa2_only': 1.7,
    'test_zram': 0.7,
}
DEFAULT = 5.0


def shards(n):
    mods = sorted(p.stem for p in Path(__file__).parent.glob('test_*.py'))
    out = [[] for _ in range(n)]
    load = [0.0] * n
    for m in sorted(mods, key=lambda m: (-WEIGHTS.get(m, DEFAULT), m)):
        i = load.index(min(load))
        out[i].append(m)
        load[i] += WEIGHTS.get(m, DEFAULT)
    return [sorted(g) for g in out]


if __name__ == '__main__':
    n, i = int(sys.argv[1]), int(sys.argv[2])
    print(' '.join(shards(n)[i]))
