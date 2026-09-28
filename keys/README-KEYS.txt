本目录是参考用:
1) immortalwrt-25.12.pem / openwrt-25.12.pem = 设备当前信任的两把(取自本地 25.12 rootfs 镜像 /etc/apk/keys/);
   它们与 master snapshot 的签名公钥不是同一把。
2) master snapshot 的公钥要从 master rootfs 里取(本机下载该 tarball 太慢,未抓;方法):
   curl -fsSL -o rootfs.tar.gz https://downloads.immortalwrt.org/snapshots/targets/armsr/armv8/immortalwrt-armsr-armv8-generic-targz-rootfs.tar.gz
   tar -xzf rootfs.tar.gz ./etc/apk/keys && ls etc/apk/keys
   再把 .pem 放进设备 /etc/apk/keys/ 即可让 apk 校验官方 snapshot 索引(否则用 --allow-untrusted)。
