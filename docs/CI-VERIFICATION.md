# Full verification in CI

The host is too small to run everything (i5-3230M, 2 cores; and the agent itself lives here), so the full
verification moved to GitHub Actions. From this cycle on the host runs focused checks only: one test file, one
migration case. The full runs are a workflow: `.github/workflows/verify.yml` (`Verify`).

## Running it

```sh
gh workflow run verify.yml -R QC3284/mu300-linux -f ref=release-20261031
gh run list --workflow verify.yml -R QC3284/mu300-linux --limit 3
gh run watch <run-id> -R QC3284/mu300-linux
```

Inputs:

- `ref` (required, default `release-20261031`): branch or tag to check out and verify.
- `tag` (optional): tag stamped into the test image. Empty means `v<UTC date>.99`; a test bundle is not a release.
- `suites` (`full` | `focused`, default `full`): `full` adds the migration suite and the whole test suite;
  `focused` keeps the bundle, the gates and the quick tests (regdb pair gate, ndp-learn, mu300-os).

The workflow file has to live on the default branch, because GitHub only dispatches workflows that are there.
It is still the `ref` input that gets checked out and verified, so this file on `main` verifies a release branch;
the rest of `main` is not involved.

## What the jobs do

| job | runner | what |
|-----|--------|------|
| `bundle` | ubuntu-24.04-arm | downloads the published base image `v2026.10.25.4` (`mu300-openwrt-rootfs.tar.gz`, pinned sha256) and builds a bundle with `tools/make-release-layout.sh` (`MU300_APK_UPGRADE=1`), adds the device-proven kernel bundle `v2026.10.31.3` (pinned sha256), writes `SHA256SUMS` (rootfs, updater, kernel, then the identity line), and runs the gates: the layout must refuse a non-AArch64 carry helper (gate A), `tools/check-update-audit.sh` must refuse an image with one (gate B), and the real bundle audit must pass (it includes the regulatory database signature check). |
| `migration` | ubuntu-24.04-arm | `full` only: runs `tools/verify/chroot-suite.sh` on the built image against the published base image as the installed system, in a chroot of the built image: the carry cases, the first-boot restore, the refusal of an image without the carry helper, the keep-list fallback, the package-owned files the user changed, and repair-dns. Needs `ALLDONE`, zero failures and at least 30 passing cases. |
| `pytest` | ubuntu-latest | `full`: `cd tests && python3 -m unittest discover -s . -p 'test_*.py'`; `focused`: `test_regdb_gate`, `test_ndp_learn`, `test_device_scripts.Os`. |
| `summary` | ubuntu-latest | collects the artifacts, writes `summary.md` (also the run step summary) and fails the run if the bundle or the test job did not pass. A skipped migration job (focused run) counts as fine. |

Artifacts: `verify-bundle` (the three assets and `SHA256SUMS`, plus `build.log`, `gate-a.log`, `gate-b.log`,
`audit.log`), `verify-chroot` (`chroot-suite.log`), `verify-pytest` (`pytest.log`), `verify-summary`
(`summary.md`). Download one with `gh run download <run-id> -R QC3284/mu300-linux -n verify-summary`.

The bundle's `SHA256SUMS` is the first thing to read: if the identity line does not match `v<the tag>`, the
bundle is not the release it says it is.

## Focused checks on the host

One test file (normal case):

```sh
cd /home/qc233/zte/mu300-work/p1-backports
nice -19 python3 -m pytest tests/test_regdb_gate.py -q
```

The migration suite locally runs under docker on an x86 host (arm64 via binfmt), the same cases the `migration`
job runs natively:

```sh
cd /home/qc233/zte/mu300-work/p1-backports
MU300_VERIFY_RUNTIME=docker MU300_VERIFY_DOCKER_IMAGE=mu300-iwrt-base:25.12.2 \
  sh tools/verify/chroot-suite.sh \
     /home/qc233/zte/mu300-work/rebuild/release-v2026.11.08.6-test/mu300-immortalwrt-rootfs.tar.gz \
     /home/qc233/zte/mu300-work/rebuild/73/mu300-openwrt-rootfs-v25.4-aurora.tar.gz \
     /home/qc233/zte/mu300-work/rebuild/.scratch/chroot-work .
```

To debug one migration case, prepare the chroot once and run the case by hand:

```sh
# prepare-chroot.py fills WORKDIR/chroot: /tmp/t holds the suite scripts, /tmp/stage the image payload
python3 tools/verify/prepare-chroot.py NEW_IMAGE OLD_IMAGE tools/verify/suite WORKDIR/chroot TAG_NEW TAG_OLD UPK_OLD_BINARY
docker run --rm --privileged --platform linux/arm64 -v WORKDIR/chroot:/rfs mu300-iwrt-base:25.12.2 \
  /bin/sh -c 'mount -t proc proc /rfs/proc; mount -t sysfs sys /rfs/sys; mount --bind /dev /rfs/dev; exec chroot /rfs /bin/sh /tmp/t/a1.sh'
```

For a focused run of one test, prefer `pytest tests/test_x.py::Class::test_y -q`; do not run the whole suite on
the host, that is what the workflow is for.

## Pins

The workflow pins its inputs, so a run verifies a bundle built from the same base every time:

- base image: release `v2026.10.25.4`, asset `mu300-openwrt-rootfs.tar.gz`, sha256
  `6c767152e80afcd5b2aec1b7eaba9dc64e11b52d411a7c20c98c22cbc951db77`;
- kernel bundle: release `v2026.10.31.3`, asset `mu300-kernel-7.2.tar.gz`, sha256
  `d3b37629fab48873192152530c173c0455263156b648a760ec87f8c69e65054b` (the device-proven bundle).

Change a pin only together with the release that makes the new asset available, and say why in the commit.
