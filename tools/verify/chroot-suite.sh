#!/bin/sh
# Full migration suite on a built release image, in a chroot (the CI job runs this on an arm64 runner).
# usage: tools/verify/chroot-suite.sh NEW_IMAGE OLD_IMAGE WORKDIR [REPO]
#   NEW_IMAGE  release rootfs tarball (tools/make-release-layout.sh output)
#   OLD_IMAGE  rootfs tarball of a published release, the system the update starts from
#   WORKDIR    scratch (chroot root, fixtures, log; removed and filled)
#   REPO       checkout to take the old mu300-user-packages from (default: the tree of this script)
#
# env:
#   MU300_VERIFY_RUNTIME=docker  run the chroot in docker (local, for an x86 host with binfmt);
#                                default: direct, which needs sudo for mount and chroot (the CI runner)
#   MU300_VERIFY_DOCKER_IMAGE    docker image that provides mount and chroot (default ubuntu:26.04)
set -eu
NEW=${1:?NEW_IMAGE}
OLD=${2:?OLD_IMAGE}
WORK=${3:?WORKDIR}
REPO=${4:-$(cd "$(dirname "$0")/../.." && pwd)}
V=$WORK/chroot
TAG_NEW=$(tar -xzOf "$NEW" ./etc/mu300/image-version)
TAG_OLD=$(tar -xzOf "$OLD" ./etc/mu300/image-version)
[ -n "$TAG_NEW" ] && [ -n "$TAG_OLD" ] || { echo "cannot read the image versions" >&2; exit 1; }
mkdir -p "$WORK"
rm -rf "$WORK/chroot"
# the old mu300-user-packages (before the repair-dns fix): the one bug case needs a binary that has the bug
UPK=$WORK/upk-old-binary
git -C "$REPO" show a42b474d^:rootfs/overlay/opt/mu300/bin/mu300-user-packages > "$UPK"
chmod 755 "$UPK"
python3 "$REPO/tools/verify/prepare-chroot.py" "$NEW" "$OLD" "$REPO/tools/verify/suite" "$V" "$TAG_NEW" "$TAG_OLD" "$UPK"
LOG=$WORK/chroot-suite.log
echo "== suite: new $TAG_NEW, old $TAG_OLD"
case ${MU300_VERIFY_RUNTIME:-direct} in
    docker)
        docker run --rm --privileged --platform linux/arm64 -v "$V:/rfs" "${MU300_VERIFY_DOCKER_IMAGE:-ubuntu:26.04}" \
            /bin/sh -c "mount -t proc proc /rfs/proc; mount -t sysfs sys /rfs/sys; mount --bind /dev /rfs/dev; exec chroot /rfs /bin/sh /tmp/t/driver.sh" 2>&1 | tee "$LOG" ;;
    direct)
        sudo MU300_VERIFY_DEBUG="${MU300_VERIFY_DEBUG:-0}" sh -c "
            mount -t proc proc \"$V/proc\" || exit 1
            mount -t sysfs sys \"$V/sys\" || exit 1
            mount --bind /dev \"$V/dev\" || exit 1
            chroot \"$V\" /bin/sh /tmp/t/driver.sh
            rc=\$?
            umount \"$V/dev\" 2>/dev/null || true
            umount \"$V/sys\" 2>/dev/null || true
            umount \"$V/proc\" 2>/dev/null || true
            exit \$rc
        " 2>&1 | tee "$LOG" ;;
    *)
        echo "MU300_VERIFY_RUNTIME must be direct or docker" >&2
        exit 1 ;;
esac
grep -q ALLDONE "$LOG" || { echo "the suite did not finish (no ALLDONE)" >&2; exit 1; }
FAILS=$(grep -c "^FAIL" "$LOG" || true)
PASSES=$(grep -c "^PASS" "$LOG" || true)
echo "== suite result: $PASSES PASS, $FAILS FAIL"
[ "${FAILS:-0}" = 0 ] || { echo "migration suite failed: $FAILS cases" >&2; exit 1; }
[ "${PASSES:-0}" -ge 30 ] || { echo "migration suite ran only $PASSES cases" >&2; exit 1; }
