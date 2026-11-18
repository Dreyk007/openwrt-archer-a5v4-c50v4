### English · [Русский](BUILDING.ru.md)

# Building the Firmware

[← README](README.md)

## Requirements
* Linux on x86-64 with Docker.
* An ordinary user (not root) in the `docker` group.
* 20 GB free on an ext4 file system.

## Build
```bash
git clone -b a5v4-25.12 https://github.com/Dreyk007/openwrt-archer-a5v4-c50v4.git
cd openwrt-archer-a5v4-c50v4
docker/run.sh ./build.sh --ccache
```
The build uses the settings of the releases. The first build also compiles the toolchain and takes long; later builds only
recompile what changed.

The firmware is `bin/targets/ramips/mt76x8/openwrt-ramips-mt76x8-tplink_archer-c50-v4-squashfs-sysupgrade.bin`. Install it as
[the README](README.md#installation) describes.

## Testing in QEMU
Test the image on the QEMU bench before you install it:
```bash
sudo modprobe -a tun ppp_generic
docker/run.sh ./build.sh --qemu --ccache
docker/run.sh --bench tests/qemu/bench.sh
```
The run ends with `Failed: 0, skipped: 0`.

## Changing the Configuration
1. Open a shell in the build container: `docker/run.sh`.
2. In the container:
   ```bash
   cp a5v4.config .config && make defconfig
   make menuconfig
   ./scripts/diffconfig.sh > a5v4.config
   exit
   ```
3. Change kernel options in `a5v4-kernel.config`.
4. Build again: `docker/run.sh ./build.sh --ccache`. If the image does not fit the flash, the build stops.
   `size-report.txt` next to the firmware shows how much room is left for the settings.

## GitHub Actions
Publish a release from your repository on GitHub:
1. *Settings → Actions → General*: select *Allow all actions and reusable workflows*.
2. In *Actions*, disable every workflow except *Build Archer A5 v4 / C50 v4 firmware*: open each one and choose
   *⋯ → Disable workflow*.
3. *Settings → General → Releases*: select *Enable release immutability*.
4. *Actions → Build Archer A5 v4 / C50 v4 firmware → Run workflow*, with the fields as they are.

The release appears in *Releases* with the tag `v<OpenWrt version>-a5v4-r<N>`.

**Verifying a download.** Each file of a release carries a signed attestation of the workflow run that built it. Check a
downloaded image with the [GitHub CLI](https://cli.github.com/):
```bash
gh attestation verify openwrt-ramips-mt76x8-tplink_archer-c50-v4-squashfs-sysupgrade.bin --repo Dreyk007/openwrt-archer-a5v4-c50v4
gh release verify-asset <release tag> openwrt-ramips-mt76x8-tplink_archer-c50-v4-squashfs-sysupgrade.bin --repo Dreyk007/openwrt-archer-a5v4-c50v4
```
