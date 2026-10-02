MU300 patches applied by upstream/build.sh (for p in /work/patches/*.patch).

Keep one patch per topic; numbering = apply order.

NOTE (2026-10-02): upstream 5.4 patches must be re-targeted when porting to 6.18 -
e.g. the Marlin3 link-policy change lives in net/bluetooth/hci_sync.c on 6.18
(hci_setup_link_policy_sync), NOT hci_core.c (hci_setup_link_policy) as on 5.4.
