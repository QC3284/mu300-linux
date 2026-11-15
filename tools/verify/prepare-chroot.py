#!/usr/bin/env python3
'''Prepare the chroot root for the migration suite (tools/verify/chroot-suite.sh).

usage: prepare-chroot.py NEW_IMAGE OLD_IMAGE SUITE_DIR OUT TAG_NEW TAG_OLD UPK_OLD_BINARY

NEW_IMAGE  the release rootfs tarball built by tools/make-release-layout.sh
OLD_IMAGE  the rootfs tarball of the system the update starts from (a published release)
SUITE_DIR  tools/verify/suite, the scripts the driver runs inside the chroot
OUT        the chroot root to fill (removed first)
TAG_NEW, TAG_OLD  the image-version of the two tarballs
UPK_OLD_BINARY   mu300-user-packages from before the repair-dns fix, taken from git history
'''
import base64
import hashlib
import os
import shutil
import subprocess
import sys


def extract(tar, dst):
    os.makedirs(dst, exist_ok=True)
    subprocess.run(["tar", "-xzf", tar, "-C", dst], check=True)


def main():
    if len(sys.argv) != 8:
        print(__doc__)
        return 2
    new, old, suite, out, tag_new, tag_old, upk = sys.argv[1:]
    shutil.rmtree(out, ignore_errors=True)
    os.makedirs(out)
    # the chroot root is the new image: its binaries and its first-boot init run the cases
    extract(new, out)
    # the installed system of the device: the old image plus the user files and the packages the user changed
    oldroot = os.path.join(out, "mnt", "mu300-disk", "openwrt")
    extract(old, oldroot)
    files = {
        "etc/openclash/config/config.yaml": ("port: 7890\nmode: rule\n", None),
        "etc/openclash/core/clash_meta": ("#!/bin/sh\n", 0o755),
        "etc/openclash/custom/mine.yaml": ("rule: mine\n", None),
        "etc/openclash/proxy_provider/Provider_C54978.yaml": ("providers: mine\n", None),
        "etc/adguardhome/adguardhome.yaml": ("http:\n  address: 0.0.0.0:3000\n", None),
        "etc/adguardhome/data/querylog.json": ("data\n", None),
        "etc/smartdns/custom.conf": ("server 223.5.5.5\n", None),
        "etc/smartdns/conf.d/mine.conf": ("address /example.com/1.2.3.4\n", None),
        "etc/ssh/ssh_host_ed25519_key": ("key\n", 0o600),
        "etc/ssh/sshd_config": ("HostKey /etc/ssh/ssh_host_ed25519_key\n", None),
        "etc/sysupgrade.conf": ("user\n", None),
        "etc/msmtprc": ("smtp: mine\n", None),
        "etc/ssl/private/mine.pem": ("private\n", None),
        "www/luci-static/aurora/fonts/aurora-font.css": ("my font\n", None),
        "root/mine.txt": ("notes\n", None),
        "etc/crontabs/root": ("0 3 * * * echo mine\n", None),
    }
    for rel, (body, mode) in files.items():
        path = os.path.join(oldroot, rel)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w") as fh:
            fh.write(body)
        if mode is not None:
            os.chmod(path, mode)
    with open(os.path.join(oldroot, "etc/hosts"), "a") as fh:
        fh.write("user line\n")
    defc = "# openclash default rules\nRULE-SET,reject\nGEOIP,CN,DIRECT\n"
    usrc = "# the rules of the user\n" + "".join("DOMAIN-SUFFIX,site%d.example,PROXY\n" % i for i in range(1, 58))
    with open(os.path.join(oldroot, "etc/openclash/custom/openclash_custom_rules.list"), "w") as fh:
        fh.write(usrc)
    conff = "port: 7890\nmode: rule\n"
    initc = "#!/bin/sh\n/etc/openclash/core/clash_meta >/dev/null 2>&1 &\n"
    initd = os.path.join(oldroot, "etc/init.d/openclash")
    with open(initd, "w") as fh:
        fh.write(initc)
    os.chmod(initd, 0o755)
    id_ = lambda d: "Q1" + base64.b64encode(hashlib.sha1(d).digest()).decode()
    installed = os.path.join(oldroot, "lib/apk/db/installed")
    with open(installed, "a") as fh:
        fh.write("\n".join(["", "C:" + id_(b"x"), "P:luci-app-openclash", "V:0.46.077-r1",
                            "A:aarch64_cortex-a53", "F:etc", "F:etc/openclash", "F:etc/openclash/custom",
                            "R:openclash_custom_rules.list", "a:0:0:644", "Z:" + id_(defc.encode()),
                            "F:etc/openclash", "R:config.yaml", "a:0:0:644", "Z:" + id_(conff.encode()),
                            "F:etc/init.d", "R:openclash", "a:0:0:755", "Z:" + id_(initc.encode())]) + "\n")
    with open(os.path.join(oldroot, "etc/apk/world"), "a") as fh:
        fh.write("luci-app-openclash\n")
    geo_def = "GEOSITE-DEFAULT-DATA\n"
    mmdb_def = "MMDB-DEFAULT-DATA\n"
    geo_user = "GEOSITE-USER-DOWNLOADED\n" + "".join("line%d\n" % i for i in range(200))
    mmdb_user = "MMDB-USER-DOWNLOADED\n" + "".join("row%d\n" % i for i in range(120))
    with open(os.path.join(oldroot, "etc/openclash/GeoSite.dat"), "w") as fh:
        fh.write(geo_user)
    with open(os.path.join(oldroot, "etc/openclash/Country.mmdb"), "w") as fh:
        fh.write(mmdb_user)
    with open(installed, "a") as fh:
        fh.write("\n".join(["", "C:" + id_(b"yo"), "P:luci-app-openclash-geo", "V:0.46.077-r1",
                            "A:aarch64_cortex-a53", "F:etc", "F:etc/openclash", "R:GeoSite.dat",
                            "a:0:0:644", "Z:" + id_(geo_def.encode()), "F:etc/openclash", "R:Country.mmdb",
                            "a:0:0:644", "Z:" + id_(mmdb_def.encode())]) + "\n")
    with open(os.path.join(oldroot, "etc/apk/world"), "a") as fh:
        fh.write("luci-app-openclash-geo\n")
    subprocess.run(["cp", "-a", oldroot, os.path.join(out, "opt/old-base")], check=True)
    tmp = os.path.join(out, "tmp")
    with open(os.path.join(tmp, "expected_rules_user.sha"), "w") as fh:
        fh.write(hashlib.sha256(usrc.encode()).hexdigest() + "\n")
    with open(os.path.join(tmp, "expected_geo_user.sha"), "w") as fh:
        fh.write(hashlib.sha256(geo_user.encode()).hexdigest() + "\n")
    with open(os.path.join(tmp, "expected_mmdb_user.sha"), "w") as fh:
        fh.write(hashlib.sha256(mmdb_user.encode()).hexdigest() + "\n")
    # the new image, whole and as the update payload the updater fetches
    stage = os.path.join(tmp, "stage")
    os.makedirs(stage, exist_ok=True)
    shutil.copy2(new, os.path.join(stage, "rootfs.tar.gz"))
    shutil.copy2(new, os.path.join(stage, "mu300-immortalwrt-rootfs.tar.gz"))
    newimg = os.path.join(tmp, "newimg")
    extract(new, newimg)
    # an image of the same version without mu300-carry: the updater has to refuse it
    nocarry_src = os.path.join(tmp, "nocarry-src")
    extract(new, nocarry_src)
    os.remove(os.path.join(nocarry_src, "opt/mu300/bin/mu300-carry"))
    nocarry = os.path.join(tmp, "new-nocarry.tar.gz")
    with open(nocarry, "wb") as fh:
        subprocess.run(["tar", "-czf", "-", "-C", nocarry_src, "."], check=True, stdout=fh)
    shutil.rmtree(nocarry_src, ignore_errors=True)
    extract(nocarry, os.path.join(tmp, "noimg"))
    # the old mu300-user-packages: the repair-dns bug case, from the one binary that had it
    shutil.copy2(upk, os.path.join(tmp, "upk-old-binary"))
    os.chmod(os.path.join(tmp, "upk-old-binary"), 0o755)
    suite_out = os.path.join(tmp, "t")
    shutil.copytree(suite, suite_out, dirs_exist_ok=True)
    for name in os.listdir(suite_out):
        os.chmod(os.path.join(suite_out, name), 0o755)
    with open(os.path.join(tmp, "suite-env.sh"), "w") as fh:
        fh.write("TAG_NEW=%s\nTAG_OLD=%s\nTAG_NOCARRY=%s\n" % (tag_new, tag_old, tag_new))
    print("prepared", out)
    print("tag_new", tag_new, "tag_old", tag_old)
    return 0


if __name__ == "__main__":
    sys.exit(main())
