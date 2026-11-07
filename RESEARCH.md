# Research and Measurements

The measurements, source checks and decisions behind this build. Until 2026-11-02 nothing had run on a router: the sizes come from test builds, everything else from the sources; [section 12](#12-tests-on-the-router) has the tests on the router since. Each section ends with its decision; decisions taken after the research carry their date. What is still to be measured or checked is listed in [TODO.md](TODO.md#checks-and-measurements).

**Contents:** [Method and sources](#method-and-sources) · [1. Hardware](#1-hardware-flash-layout-and-installation) · [2. Programs](#2-size-of-the-programs) · [3. Kernel](#3-size-of-the-kernel) · [4. IPv6](#4-ipv6) · [5. Compiler](#5-compiler-and-flags) · [6. mt76 fixes](#6-wi-fi-driver-fixes-from-mt76-master) · [7. WISP](#7-wi-fi-client-and-access-point-wisp) · [8. Routing, acceleration, IPTV](#8-routing-acceleration-and-iptv) · [9. Hardening](#9-kernel-hardening) · [10. What the image leaves out](#10-what-the-image-leaves-out) · [11. zram](#11-zram) · [12. Router tests](#12-tests-on-the-router) · [13. VPN](#13-vpn-wireguard-and-amneziawg) · [14. DoH](#14-encrypted-dns-doh) · [15. The 4pda thread](#15-the-4pda-thread) · [16. The OpenWrt forum](#16-the-openwrt-forum) · [Sources](#sources)

## Method and sources

**Preliminary research** (2026-10-31, kept outside the repository): test builds of OpenWrt 25.12.6 for this router on the build PC (24 threads), without a router. The sizes of sections 2, 3 and 5 come from it.

* **Programs:** the official ImageBuilder of 25.12.6 (`ramips/mt76x8`), exact size of `root.squashfs`. The ImageBuilder reproduces the official package set byte for byte, so the differences are the packages alone.
* **Kernel:** Linux 6.12.112 with the patches of OpenWrt 25.12.6 (generic and ramips), the toolchain of the official SDK, the kernel configuration of the SDK as the base. Flash = `vmlinux` compressed with LZMA as OpenWrt does it; RAM = text + data + bss. The base build matched the released `kernel.bin` (2074.6 against 2074.2 KiB).
* **Full builds:** the whole tree; image size `sysupgrade.bin` rounded to the 64 KiB erase block.

**An independent review of it** (2026-10-31, also outside the repository), checked here against the sources:

* Confirmed: `NF_TABLES_INET` depends on `IPV6`, so a kernel without IPv6 leaves fw4 without its tables ([section 4](#4-ipv6)); a hybrid profile of the programs ([section 5](#5-compiler-and-flags)); a watchdog instead of travelmate ([section 7](#7-wi-fi-client-and-access-point-wisp); travelmate was chosen instead); LAN traffic leaking through the WAN port during boot (also on the OpenWrt wiki; deferred in TODO.md).
* Wrong: the mt76 commits `16f56d6` and `a89e409` do not exist, `82c085f` ("wake queues after reconfig") is already part of the 25.12 pin, and several commit descriptions are swapped ([section 6](#6-wi-fi-driver-fixes-from-mt76-master)); `factory-uboot` has 192 KiB, not 128; software flow offloading does work together with SQM (on the AX3200).

**Source checks** (2026-10-31 and 2026-11-01): tag `v25.12.6`, the Linux stable tree at `v6.12.112`, `openwrt/mt76` master at `0936617`, the feeds pinned in `feeds.conf.default` (packages `093d551675`, luci `75a306df84`), the release files of 25.12.6 (`profiles.json`, the manifest of `ramips/mt76x8`), the OpenWrt wiki of the Archer C50 and DeviWiki.

**Build environment and reference build** (2026-11-01). The container of `docker/Dockerfile` (Debian testing, host GCC 16.2.0) builds OpenWrt 25.12.6 without changes. `reference.config` is the official build configuration (`config.buildinfo` of ramips/mt76x8) reduced to this router; it keeps `ALL_KMODS`, the kernel debug information, `PKG_ASLR_PIE_REGULAR` and the LuCI set of the release. Built from source it matches the official image:

| | Reference build | Official 25.12.6 |
|---|---|---|
| `sysupgrade.bin` | 5953 KiB (1663 KiB free of 7616) | 5952.3 KiB |
| Kernel in flash | 2075 KiB | 2075 KiB (preliminary research) |
| `root.squashfs` | 3828 KiB | |
| Kernel in RAM (`vmlinux.elf`, text + data + bss) | 7056 KiB | 7063 KiB (preliminary research) |
| Loadable modules in the image | 57 | |

The build took 18 min on the build PC (24 threads, empty compiler cache); the same seed for QEMU afterwards 7 min, since both targets share the `mipsel_24kc` packages of one tree. OpenWrt rebuilds a package when its own options change, not when the toolchain or the global compiler flags do, and all GCC versions share one target staging directory: the first GCC 15 build in the tree of the reference (GCC 14) linked procd against the host's `libubox` (`file in wrong format`). `build.sh` therefore cleans the target build when these change. The kernel to measure is `build_dir/…/linux-ramips_mt76x8/vmlinux.elf`: `linux-*/vmlinux` is the last kernel built, the one of the initramfs image, with 3.8 MB of root file system in its `.init.data`.

**QEMU bench** (`tests/qemu/bench.sh`, 2026-11-01). malta/le runs the same `mipsel_24kc` programs as the router, with `-cpu 24KEc -m 64`, the root file system on a virtual disk, a LAN client and a WAN side in network namespaces. It checks DHCP, DNS (names of the router and of DHCP clients, forwarding), the NTP server, LuCI (page, login, an rpc call, the Russian translation), the WAN address, fw4, NAT, closed SSH and LuCI on the WAN, `reject` (TCP reset and ICMP port unreachable), the absence of IPv6 settings without IPv6 in the kernel, flow offloading over DHCP and PPPoE, WireGuard (handshake, SSH to the router through the tunnel), IPTV (a multicast stream from the WAN to a LAN client through `igmpproxy`, none without it, the same stream over HTTP from `udpxy`), WPA2 between two `mac80211_hwsim` radios, the Wi-Fi drivers of the router (they load without hardware), the kernel log and settings across a reboot. The official malta image and the QEMU build of `reference.config` pass all checks, except those the image has nothing for (WireGuard; the NTP server, which is off in the official configuration). A test build with WireGuard added passed the WireGuard checks, and the NTP check passed with the server switched on. Its numbers are not the router's: TCG emulation has no relation to the speed of a 24KEc, and the malta kernel needs more RAM (11.7 MB for the same seed); `MemAvailable` (about 16 MB of 52 MB) only compares builds with each other.

Pitfalls of the bench, so they are not met again:
* On malta the first `-nic` is the onboard card (PCI slot `0x0b`) and becomes `eth0`.
* OpenWrt's dnsmasq never forwards the special-use domains of RFC 6761 (`.test`, `.local`, …; `/usr/share/dnsmasq/rfc6761.conf`), and its rebind protection drops answers in the documentation ranges of RFC 5737, which dnsmasq treats as private; the internet host of the bench is 198.18.0.1 under an ordinary domain.
* hostapd refuses the world domain `00` that `mac80211_hwsim` radios start with (`Cannot enable IEEE 802.11d without setting the country_code`); in 25.12 the default Wi-Fi interfaces also carry `disabled '1'` of their own.
* The bench runs as root; a root-owned `tmp/` makes the next build fail its `working-gcc` check, so the bench returns `tmp/` to the owner of the checkout.
* A bare `wait` in the bench waits for its long-running helpers too (dnsmasq, `pppoe-server`); wait for a PID.
* `MemAvailable` on 64 MB is a rough measure: OpenWrt sets `vm.min_free_kbytes` to 8192 on 64 MB (`/etc/init.d/sysctl`), and the estimate subtracts the reserve and up to the low watermark (10 MB) of the page cache, so it moves with what happens to be cached when it is read. Right after SSH came up it showed 19016 KiB for the IPv6 step and 14240 KiB for the packages step; read 90 s after boot the two were 15464 and 15344 KiB, with the same processes and slab. The bench reads it 90 s after boot since 2026-11-02.
* A boot without network is examined on the serial console: QEMU with `-serial stdio` and commands piped in after the boot (the bench's `--hook` needs SSH).

**Pitfalls for the tests on the router**, from the AX3200 build:

* The Wi-Fi link rate changes after every reconnect, so firmwares or settings are compared only in interleaved runs on one connection.
* Power save of the Wi-Fi client adds latency spikes of tens of ms: switch it off for latency tests (`iw dev <wlan> set power_save off`), except in the power save tests.
* CPU per Mbit/s is only comparable at similar throughput.
* The Ethernet ports are 100 Mbit/s: wired tests only show the CPU load at line rate. The CPU limits Wi-Fi ↔ Wi-Fi, the Wi-Fi client (WISP) ↔ LAN and WireGuard.
* Do not ping the ISP gateway at a high rate: gateways rate-limit ICMP. Ping external hosts (1.1.1.1, 8.8.8.8).

## 1. Hardware, flash layout and installation

| Part | What it is | Notes |
|---|---|---|
| SoC | MediaTek MT7628AN, MIPS 24KEc, 575 MHz, one core | 64 KiB I-cache, 32 KiB D-cache, no FPU; OpenWrt builds for `CPU_TYPE:=24kc` (`mipsel_24kc`) |
| Flash | 8 MiB SPI NOR, 64 KiB erase blocks | GigaDevice GD25Q64 on the unit of the tests; Winbond W25Q64 and cFeon EN25QH64A on other units ([section 15](#15-the-4pda-thread)) |
| RAM | 64 MiB DDR2 (ESMT M14D5121632A) | |
| 2.4 GHz | in the MT7628, 2×2 802.11n | `mt7603e` (`kmod-mt7603`, a default package of the subtarget) |
| 5 GHz | MT7612E on PCIe, 2×2 802.11ac | `mt76x2e` (`kmod-mt76x2`, the device package) |
| Ethernet | switch in the SoC, 4 × LAN + 1 × WAN, 100 Mbit/s | `rt5350-eth` frame engine, `rt3050-esw`, `swconfig` |
| Other | four fixed antennas; FCC ID TE7C50V3; 9 V / 0.85 A | |

Partitions (`target/linux/ramips/dts/mt7628an_tplink_8m-split-uboot.dtsi`):

| Partition | Offset | Size | Contents |
|---|---|---|---|
| `factory-uboot` | `0x000000` | 192 KiB | first bootloader: TFTP and web recovery; read-only |
| `boot` | `0x030000` | 128 KiB | second bootloader, which starts the kernel; read-only |
| `firmware` | `0x050000` | 7616 KiB | OpenWrt: kernel, squashfs, settings (jffs2) |
| `config` | `0x7c0000` | 64 KiB | settings of the stock firmware; read-only |
| `rom` | `0x7d0000` | 64 KiB | base MAC address at `0xf100`; read-only |
| `romfile` | `0x7e0000` | 64 KiB | flag of the stock firmware's upgrade (below) |
| `radio` | `0x7f0000` | 64 KiB | Wi-Fi calibration: MT7628 at `0x0`, MT7612E at `0x8000`; read-only |

* The C50 v3 is the same hardware without the split bootloader and has 7808 KiB for the firmware; the C50 v4 has 7616 KiB (`IMAGE_SIZE` in `target/linux/ramips/image/mt76x8.mk`).
* **Archer A5 v4 / v4.20:** not described in OpenWrt. Users of the [4pda thread](https://4pda.to/forum/index.php?showtopic=964235) have installed the official C50 v4 images from 19.07 to 25.12.5 on it, and the unit of the tests has run OpenWrt before. The Archer A5 v6 / C50 v6 is other hardware (MT7613BEN for 5 GHz, driver `mt7663`) and takes only the images of the C50 v6 ([section 15](#15-the-4pda-thread)).
* **Official 25.12.6:** only `sysupgrade.bin` (5952.3 KiB) and `initramfs-kernel.bin`; the default packages include `apk-mbedtls`, `ca-bundle`, `uclient-fetch`, `libustream-mbedtls`, `odhcp6c`, `odhcpd-ipv6only`, `wpad-basic-mbedtls` (`profiles.json` of the release). OpenWrt lists devices with 8 MiB of flash and 64 MiB of RAM as not recommended for new purchases, but builds 25.12 for them.
* **No `factory.bin`:** the commit that added the device ([`01dcd574a248`](https://github.com/openwrt/openwrt/commit/01dcd574a24864c10a9c4df4304a3ce0da5c11a9), David Bauer, 2018) explains that every installation method needs the second U-Boot inside the image, which OpenWrt does not ship. **A `sysupgrade.bin` uploaded in the stock web interface bricks the router** (a reboot loop with blinking LEDs; OpenWrt wiki).
* **TFTP recovery:** the first bootloader loads `tp_recovery.bin` from `192.168.0.66` (the computer, on a LAN port) when the reset button is held at power-on until the WPS LED lights (about 8–10 s); after each attempt wait at least 3 minutes or until three or more LEDs light, or the router may brick (wiki). A `tp_recovery.bin` with OpenWrt is either the tested file "OpenWRT - Archer A5 v4 (C-50).zip" of the 4pda thread (a 19.07 snapshot) or made from a TP-Link firmware of the same model (`tpl.bin`) and an OpenWrt `sysupgrade.bin` (`owrt.bin`), as the commit describes:
  ```sh
  dd if=/dev/zero of=tp_recovery.bin bs=196608 count=1
  dd if=tpl.bin of=tmp.bin bs=131584 count=1
  dd if=tmp.bin of=boot.bin bs=512 skip=1
  cat boot.bin >> tp_recovery.bin
  cat owrt.bin >> tp_recovery.bin
  ```
  `boot.bin` (the first 131584 bytes of `tpl.bin` followed by `owrt.bin`) can also be uploaded in the stock web interface; the wiki links community 19.07 images made this way. After any of these, install the target image with `sysupgrade -n`: on 4pda, upgrades from 19.07 with kept settings left the router without Wi-Fi.
* **Web recovery:** the stock firmware sets a flag in `romfile` before it writes and clears it afterwards. A router that boots with the flag set starts the web recovery of the bootloader on `192.168.0.1`.
* **Back to stock:** TFTP with the stock recovery file of the 4pda thread ("Восстановление стока Archer A5 v4.rar"); for EU firmware the wiki strips the first 512 bytes: `dd if=orig.bin of=tp_recovery.bin skip=1 bs=512`.
* **Backup:** on OpenWrt, `cat /proc/mtd` lists the partitions; save each of them, e.g. `for m in $(ssh root@192.168.1.1 "grep -o '^mtd[0-9]*' /proc/mtd"); do ssh root@192.168.1.1 "cat /dev/$m" > $m.bin; done`. `radio` and `rom` cannot be replaced: another unit's dump brings a bricked router back, but its Wi-Fi then runs with someone else's calibration. From the stock firmware only a programmer (CH341A with a clip) reads the flash.
* **Risks:** two routers on the OpenWrt forum were bricked by badly prepared `tp_recovery.bin` files (a wrong header, an overwritten calibration partition); one user on 4pda could not go back to older versions after a TFTP flash of 25.12.5, for reasons unknown.
* **UART:** next to the Ethernet ports, 115200 8N1, TP-Link pinout, 3.3 V TTL; holding `4` at boot stops in the U-Boot console.
* **Known issues on the wiki:** poor 2.4 GHz range of some v4 units, fixed in 19.07.7 by an EEPROM chip ID of mt76 (`0x7600`, part of `mt7603_check_eeprom()` ever since); LAN traffic leaks through the WAN port during boot, since the switch has no port isolation until the kernel configures it.
* **The leak, seen on the router** (2026-11-03): after a reboot a Raspberry Pi on the LAN had an address of the ISP's subnet (the router NAKed its renewal as `wrong network`) and had to be replugged. The cause is in `esw_rt3050.c`: at probe (3.2 s after the kernel starts) and at every reset of the switch the driver applies an empty configuration, all ports in one VLAN with all PHYs on, and the VLANs of the board only come from userspace: preinit applies the LAN VLAN at about 23 s, netifd the full configuration at about 70 s. The bootloader of TP-Link writes `disable switch phyport` before it starts the kernel (its boot logs on the wiki), so OpenWrt itself opened the bridge. The driver of OpenWrt main is the same; no fix was found (wiki, forum, patchwork). **Fix (2026-11-03):** the driver keeps the ports that `mediatek,portmap` leaves out of the LAN (`0x3e`: port 0, the WAN port) disabled from a reset until userspace applies a configuration. **Checked on the router** (2026-11-03, `dmesg`): before, `port 0 link up` came at 6.3 s next to the LAN ports; with the fix the LAN port came up at 7.5 s and the WAN port only at 25.2 s, after preinit's switch configuration (which leaves it out of the LAN VLAN), and at netifd's reset it stayed down from 75.7 s until its VLAN was applied at 77.4 s. The Raspberry Pi got its LAN lease, `logread` had no `DHCPNAK`.

**Decision:** profile `tplink_archer-c50-v4`; the build delivers `sysupgrade.bin` only. The README of the first release describes the installation from OpenWrt (`sysupgrade -n`) and from the stock firmware through TFTP recovery, always after a full flash dump.

## 2. Size of the programs

Base set of the preliminary research: `luci-light` with the firewall, PPP and WireGuard pages, PPPoE, `dnsmasq`, `dropbear`, WireGuard, `zram-swap`; without the IPv6 clients (`odhcp6c`, `odhcpd`), `luci-ssl` and attended sysupgrade. The NTP server is part of busybox already (`ntpd` with `FEATURE_NTPD_SERVER`, a busybox default), and busybox builds no `telnetd` in 25.12.

| Variant | `root.squashfs`, KiB | Difference | Wi-Fi client | Wi-Fi security | `mbedtls` |
|---|---|---|---|---|---|
| Base (`wpad-basic-mbedtls`, `apk`, HTTPS) | 3931 | — | yes | WPA2/WPA3, 11r, 11w | yes |
| Base without `apk` and the HTTPS client | 3699 | −232 | yes | WPA2/WPA3, 11r, 11w | yes |
| **`wpad-basic` (internal crypto), no `apk`, no HTTPS** | **3456** | **−475** | **yes** | **WPA2, 11r, 11w** | **no** |
| `wpad-mini`, no `apk`, no HTTPS | 3401 | −530 | yes | WPA2-PSK only | no |
| `hostapd-basic`, no `apk`, no HTTPS | 3316 | −615 | **no** | WPA2, 11r, 11w | no |

* `hostapd-*` has no `wpa_supplicant`, so the router could not be a Wi-Fi client. `wpad-mini` saves 55 KiB more at the cost of 802.11w (PMF) and 802.11r.
* Without the HTTPS client (`libustream-mbedtls`, `ca-bundle`, `uclient-fetch`) the router downloads nothing over HTTPS. `libustream-mbedtls=m` in the seed lets `uhttpd` build without putting the library into the image.
* travelmate pulls in `curl`, `mbedtls` and `ca-bundle`: +692 KiB of squashfs ([section 7](#7-wi-fi-client-and-access-point-wisp)).
* The largest remaining packages (estimated compressed share): libc 277 KiB, mac80211 247, nftables 233, busybox 182, dnsmasq 120, luci-base 118, cfg80211 118, ip-tiny 108, ppp 102, dropbear 86. Trimming busybox further would give 20–40 KiB.
* `ip-tiny` came in only through `wireguard-tools`, which accepts busybox `ip` instead (`DEPENDS:=+!BUSYBOX_CONFIG_IP:ip +!BUSYBOX_CONFIG_FEATURE_IP_LINK:ip`); the official image has no `ip-tiny`.

**Decision:** `wpad-basic`, no `apk`, no HTTPS client of its own, busybox `ip`; the complete list of what the image leaves out is [section 10](#10-what-the-image-leaves-out). WPA3 is not needed; the client mode and PMF stay. **2026-11-02:** WPA3 after all, since `mbedtls` is in the image for libcurl ([section 7](#7-wi-fi-client-and-access-point-wisp)).

**Measured in this tree** (2026-11-01, the packages step; the kernel and IPv6 steps done; KiB). The step removed what [section 10](#10-what-the-image-leaves-out) lists and added LuCI in Russian, WireGuard, travelmate and IPTV:

| | Image | Kernel in flash | `root.squashfs` | Kernel in RAM |
|---|---|---|---|---|
| Before (IPv6 step) | 5377 | 1793 | 3536 | 6018 |
| **The packages step** | **5633** | **1823** | **3753** | **6105** |

Each variant below changes one thing of the packages step; the difference is that of `root.squashfs`:

| Variant | `root.squashfs` | Difference | Notes |
|---|---|---|---|
| without travelmate, `luci-app-travelmate` and its translation, `curl`, `libcurl`, `mbedtls`, `ca-bundle` | 3155 | −598 | the whole cost of WISP with travelmate; less than the 692 KiB of the preliminary research, since libcurl is built without HTTP/2 (`libnghttp2`), zlib, FTP and `file://` (travelmate only uses HTTP(S) with cookies) |
| libcurl without TLS (`LIBCURL_NOSSL`) | 3505 | −248 | no `mbedtls`; HTTPS captive portals fail, `ca-bundle` stays |
| `wpad-basic-mbedtls` (WPA3) instead of `wpad-basic` | 3770 | +17 | `mbedtls` is in the image anyway for libcurl |
| without the Russian translation of LuCI (`LUCI_LANG_ru`) | 3674 | −79 | 4 packages: base, firewall, travelmate, udpxy |
| without `igmpproxy`, `udpxy`, `luci-app-udpxy` and its translation | 3713 | −40 | |
| `ip-tiny` instead of busybox `ip` | 3858 | +105 | |
| with `urngd` | 3759 | +6 | |
| without `rpcd-mod-rrdns` | — | ≈ −4 | the apk is 4 KiB; a dependency of the `luci-light` collection, so it stays (the bar was 8 KiB) |
| PIE off for the network-facing daemons | 3649 | −104 | wpad, dnsmasq, pppd, dropbear, procd, rpcd, ubus and uhttpd without PIE are 16–26 % smaller (wpad 775 → 612 KB, dnsmasq 222 → 180 KB): about 320 KB less code in RAM while they run; their code addresses are then no longer randomised |

WireGuard costs 30 KiB of kernel flash and 87 KiB of kernel RAM (built in) and about 41 KiB of programs (`wireguard-tools` 27, `luci-proto-wireguard` 12, `resolveip` 2 KiB as apk).

* busybox has the `ip` applet in its default configuration, but `BUSYBOX_CONFIG_IP` exists in `.config` only with `CONFIG_BUSYBOX_CUSTOM`; without it `wireguard-tools` (`+!BUSYBOX_CONFIG_IP:ip`) pulled `ip-tiny`. netifd's WireGuard handler calls `ip -br link show`, which busybox does not know; it then adds the link, which is what the check is for. The QEMU bench passes the WireGuard checks with busybox `ip`.
* `zlib` came back with the default options of libcurl and left with them.
* **busybox applets** (2026-11-01): busybox of the packages step built without one applet at a time; the difference of the binary compressed with `xz -9e` (the whole busybox: 451 KB, 207 KiB compressed). Used: whether a script of the image calls it.

| Applet | KiB | Used by the image | What is lost |
|---|---|---|---|
| `hwclock` | 1.0 | `sysfixtime` (only with an RTC); `system` on every start (`hwclock -u --systz`) | nothing: the board has no RTC, and the time zone of the kernel only matters to FAT and the like |
| `mkswap`, `swapon`, `swapoff` | 1.0 | no | nothing: the kernel has no swap |
| `taskset` | 0.7 | no | nothing: one core |
| `brctl` | 2.8 | no | the old bridge tool; netifd and `ip link` do bridges |
| `ifconfig` | 3.1 | no | the old interface tool; busybox `ip` stays |
| `netstat` | 2.5 | no | the list of sockets and connections |
| `nslookup` | 2.6 | no | DNS lookups on the router (the QEMU bench uses it) |
| `traceroute` | 2.1 | no | route tracing |
| `top` | 1.9 | no | the process monitor |
| `time` | 1.6 | no | timing of commands |
| `route` | 1.4 | `/usr/share/udhcpc/default.script` | the old routing tool |
| `nc` | 0.5 | no | netcat |
| `less` | 3.2 | no | the pager |
| `vi` | 11.0 | `sysupgrade -i` | editing files on the router |
| `crond`, `crontab` | 3.1 | `/etc/init.d/cron` | scheduled tasks (LuCI → System → Scheduled Tasks) |
| `du`, `cmp`, `dmesg`, `mknod`, `nice`, `chroot`, `free` | 0.3–0.8 each | | |
| `clear`, `reset`, `resize`, `seq`, `yes`, `fsync`, `uptime`, `mkfifo` | below 0.2 each | | |

  The first four rows (5.5 KiB together) have no function on this router; the tools below them are for diagnostics and use. `/etc/init.d/system` sets the time zone of the kernel with `hwclock -u --systz` without checking for an RTC, so without `hwclock` it would fail with `hwclock: not found` on every start (found when the applets were removed); `packet-steering.uc` calls `taskset` only with two CPUs or more. The preliminary research estimated 20–40 KiB for trimming busybox; all candidates together are about 45 KiB.

**Decision (2026-11-01):** as approved. **2026-11-02:** busybox without `brctl`, `mkswap`, `swapon`, `swapoff` and `taskset` (`root.squashfs` −4 KiB); `hwclock` stays (above). libcurl keeps TLS; libcurl without it heads the space reserve in [TODO.md](TODO.md#space-reserve). WPA3 is taken ([section 7](#7-wi-fi-client-and-access-point-wisp)): `root.squashfs` 3751 → 3769 KiB with the travelmate patch and the firewall defaults of the same day, the image stays at 5633 KiB. With it, libcurl without TLS saves only 18 KiB (3769 → 3751 KiB), since `mbedtls` stays for wpad. PIE stays on, turning it off is in the space reserve; seccomp stays off (no service of the image sets a policy, [section 10](#10-what-the-image-leaves-out)).

## 3. Size of the kernel

| Variant | Flash, KiB | Kernel RAM, KiB | Cost |
|---|---|---|---|
| Official configuration | 2075 | 7063 | — |
| Without IPv6 | 1967 (−108) | 6696 (−367) | IPv6 (see [section 4](#4-ipv6)) |
| Without small things (debugfs, magic SysRq, seccomp, BPF JIT, multicast routing, multipath, xattr, GPIO sysfs, USB PHY) | 2008 (−66) | 6823 (−240) | nothing the build needs |
| Without IPv6 and small things | 1897 (−178) | 6448 (−615) | |
| + without `ALL_KMODS` (only the image's modules) | 1636 (−439) | 5572 (−1491) | official kmods do not install |
| + `TRIM_UNUSED_KSYMS` | **1452 (−623)** | **4948 (−2115)** | any new module needs a kernel rebuild |
| Without IPv6 and small things, hardening off | 1888 (−187) | 6423 (−640) | kernel protection for 9 KiB |

All at `-Os`. The official kernel is built with `CONFIG_ALL_KMODS=y` and carries built-in options for hundreds of optional modules (XFRM, BPF, SCSI, USB, sound); this is the largest part of the difference. Multicast routing is part of the "small things" here; it stayed for IPTV and went with it on 2026-11-06 ([section 8](#8-routing-acceleration-and-iptv)).

* **Built-in modules:** the 45 modules the image always loads (netfilter/nftables, flow table, PPP/PPPoE, WireGuard, zram, `leds-gpio`) built into the kernel make it 149 KiB larger in flash and 449 KiB in RAM, but the modules themselves go away (216 KiB of flash, 732 KiB of RAM, since every module is rounded up to whole pages): about −67 KiB of flash and −280 KiB of RAM. They do not get faster: OpenWrt allocates MIPS modules next to the kernel and builds them without long calls (`target/linux/generic/hack-6.12/301-01-…`, `301-02-mips-replace-mlong-calls-with-mno-long-calls-if-poss.patch`). 22 modules stay: cfg80211, mac80211, mt76 and their crypto.
* **Options without a switch of their own** go into a kernel configuration fragment: OpenWrt merges `env/kernel-config` last into the target configuration (`LINUX_KCONFIG_LIST` in `include/target.mk`), but its own `CONFIG_KERNEL_*` options and the `KCONFIG` of the selected kmods still override it. `/env` is in `.gitignore`, so the fragment is tracked under another name and copied by `build.sh`.
* `TRIM_UNUSED_KSYMS` needs a whitelist of the symbols that the modules built outside the kernel tree (mac80211, mt76) use: `nm -u` over the image's modules gave 1311 symbols.
* `small_flash` targets already build without swap, `KALLSYMS`, cgroups, namespaces, POSIX message queues, AIO, `FHANDLE`, `FANOTIFY` and ELF core dumps, and with `PROC_STRIPPED` (`config/Config-kernel.in`); their kernel is `-Os` unless set otherwise.
* The budget of the preliminary research put the official kernel at ≈ 6900 KiB of RAM, this table at 7063 KiB (a `vmlinux` built with the official configuration). The router will tell (`dmesg` memory line, `/proc/modules`).

**Measured in this tree** (2026-11-01, the kernel step of the plan; the official package set with GCC 15.3.0, IPv6 still in; each row adds one change to the row above; KiB):

| Change | Image | Kernel in flash | `root.squashfs` | Kernel in RAM | Modules in the image (text + data + bss) |
|---|---|---|---|---|---|
| Start: official set, GCC 15.3.0 | 5889 | 2067 | 3804 | 7022 | 57 |
| `ALL_KMODS` off | 5697 | 1905 | 3771 | 6449 | 57 |
| Kernel `-O2` | 6145 | 2255 | 3864 | 7588 | 57 (1659) |
| The modules the image always loads built in | 6081 | 2401 | 3653 | 8048 | 9 (1169) |
| The approved options off, with seccomp and `procd-seccomp` | 5761 | 2134 | 3609 | 7169 | 9 (1085) |
| `TRIM_UNUSED_KSYMS` | **5569** | **1927** | **3608** | **6460** | **9 (1085)** |

* The image is rounded up to 64 KiB erase blocks; kernel plus `root.squashfs` is the finer measure.
* **`-O2`** costs 350 KiB of kernel in flash and 1139 KiB of kernel RAM here, more than the preliminary research measured on its trimmed kernel (270 / 856): the untrimmed kernel has more code to grow.
* **Built in:** 48 modules: netfilter and nftables, NAT and the flow table, PPP and PPPoE, the crypto of mac80211, `leds-gpio`. 9 stay modules: cfg80211, mac80211, mt76 (5) and `gpio-button-hotplug`, built outside the kernel tree. Kernel and squashfs together lost 65 KiB of flash; text + data + bss rose by 30 KiB (+460 kernel, −490 modules), but every module takes whole pages for its sections: on the QEMU bench `MemAvailable` after boot rose from 15976 to 18020 KiB (that build also had WireGuard built in). `NF_TABLES_BRIDGE`, on in the generic configuration, would have come in with nf_tables; as a module no package of the image installed it, so it is off.
* **The approved options** (debugfs with that of mac80211, magic SysRq, the BPF syscall and JIT, multipath routing, GPIO sysfs, USB, seccomp) took 267 KiB of kernel flash and 879 KiB of kernel RAM, and 84 KiB of module RAM (mac80211 without debugfs). Seccomp alone: kernel 4 KiB, `procd-seccomp` 12 KiB, kernel RAM 12 KiB. Bridge VLAN filtering and the xattrs of jffs2 and tmpfs stay ([section 10](#10-what-the-image-leaves-out)); VLAN filtering costs 13 KiB of flash and 41 KiB of RAM.
* **`TRIM_UNUSED_KSYMS`:** −207 KiB of kernel flash, −709 KiB of kernel RAM. The whitelist `a5v4-ksyms.txt` holds the 422 symbols that the modules of the router (366) and of the QEMU build (405, with `mac80211_hwsim` and `pcnet32`) take from the kernel; `build.sh` checks after every build that the kernel exports all symbols the image's modules need.
* **Debug information:** `CONFIG_KERNEL_DEBUG_INFO` does not switch it off on Linux 6.12, where the generic configuration selects `DEBUG_INFO_DWARF_TOOLCHAIN_DEFAULT`. A test build without the official `KERNEL_DEBUG_*` settings had the same image (5697 KiB) and kernel RAM (6447 against 6449 KiB). The information only goes to `vmlinux.debug` of the build tree; with `KALLSYMS` off it is what decodes the addresses of an Oops, so the seed keeps the official settings.
* **A trap of the build system:** a package keeps the dependencies of the configuration it was built with. `base-files`, built with `USE_SECCOMP`, kept pulling `procd-seccomp` into the image after seccomp was turned off. `build.sh` checks that every package of the image is selected and rebuilds the packages that pull in others.

**Decision:** `ALL_KMODS` off, `TRIM_UNUSED_KSYMS` with a whitelist, the permanent modules built in, the approved options off ([section 10](#10-what-the-image-leaves-out)) except bridge VLAN filtering and the xattrs, multicast routing on (off since 2026-11-06, with IPTV), hardening on ([section 9](#9-kernel-hardening)). Done on 2026-11-01.

## 4. IPv6

The build does not need IPv6, but the kernel cannot drop it without breaking the firewall:

1. **The build option is gone.** `config IPV6` is `def_bool y` in `config/Config-build.in` since [`832e7b8172`](https://github.com/openwrt/openwrt/commit/832e7b817221d288df76b763ca12c585365db5d8) ("build: always set CONFIG_IPV6", 2022: disabling it "breaks build"). `CONFIG_KERNEL_IPV6` follows it.
2. **firewall4 needs `kmod-nft-offload`, which depends on `@IPV6`** (`package/kernel/linux/modules/netfilter.mk`); it is the only hard `@IPV6` among the image's packages, the others use `+IPV6:`. With `IPV6` turned back into an option and switched off, the build silently picks the old `firewall` (fw3, iptables) as `uci-firewall`.
3. **The kernel has no `inet` tables without IPv6.** In Linux 6.12.112 `net/netfilter/Kconfig` has `config NF_TABLES_INET` with `depends on IPV6` (and `select NF_TABLES_IPV6`). fw4 always creates `table inet fw4` and the flowtable in it. A kernel without IPv6 builds fine, but the firewall, NAT and flow offloading do not start on the router. The test builds of the preliminary research had IPv6 off in the kernel; they were never booted, so this did not show.
4. **`config_generate` writes IPv6 settings** only when `/proc/sys/net/ipv6` exists (`ula_prefix`, `ip6assign`, the `wan6` interface with `proto dhcpv6`); without IPv6 in the kernel it writes none. With IPv6 in the kernel but without `odhcp6c`, `wan6` would stay in an error state.

| Option | Flash / RAM | Changes |
|---|---|---|
| **A.** No IPv6 in the kernel, patched netfilter | −108 KiB / −367 KiB | a kernel patch that lets `NF_TABLES_INET` build without IPv6 and puts the IPv6 branches of `nft_chain_filter.c`, `nft_reject_inet.c`, `nft_fib_inet.c`, `nf_flow_table_inet.c`, `nf_flow_table_ip.c` and `nft_flow_offload.c` under `IS_ENABLED(CONFIG_IPV6)`; `IPV6` an option again; `@IPV6` removed from `kmod-nft-offload`; the IPv6 rules removed from the default firewall configuration |
| **B.** IPv6 in the kernel, no IPv6 programs | 0 | `odhcp6c`, `odhcpd-ipv6only` and `luci-proto-ipv6` left out; `wan6`, `ula_prefix` and `ip6assign` removed on the first boot |
| **C.** No IPv6 and no fw4 | more than A | own nftables rules in `table ip`; no firewall pages in LuCI |

Without IPv6 the programs build smaller too: busybox drops `FEATURE_IPV6` (`default y if IPV6`). OpenWrt passes `-DNO_IPV6` to dnsmasq, but dnsmasq 2.93 no longer knows the option and always has IPv6 (`compile time options: IPv6` in its log on the router).

**Decision (2026-11-01): option A** — IPv6 out of the kernel and the programs. The patch is proven in QEMU first (fw4 tables, NAT, `reject`, flow offloading, dnsmasq, uhttpd and dropbear without IPv6). If it cannot work, option B, after a new decision. Option C is rejected (no firewall settings in LuCI).

**Implemented (2026-11-01):** `target/linux/generic/hack-6.12/950-netfilter-inet-tables-without-ipv6.patch`, `IPV6` an option again in `config/Config-build.in` (as before `832e7b8172`), `kmod-nft-offload` without `@IPV6`; the seed turns `IPV6` off.

* A test kernel without IPv6 showed what actually breaks, less than the list above: the inet NAT registration (`nf_nat_proto.c` registers the IPv6 NAT hooks for inet chains: compile error), the inet route chain (`nft_chain_route.c`: compile error), and the IPv6 calls of reject and fib in the inet family (`nft_reject_inet.c`, `nft_fib_inet.c`: link errors). `NFT_FIB_INET` also depended on `NFT_FIB_IPV6`. The flowtable (`nf_flow_table_inet.c`, `nf_flow_table_ip.c`, `nft_flow_offload.c`) and the filter chains (`nft_chain_filter.c`) build and link unchanged: `ipv6_find_hdr()` and the other helpers of `net/ipv6/exthdrs_core.c` are part of every kernel (`obj-y`), their IPv6 code just never sees a packet. inet chains still register their hooks for IPv6 too (`nf_register_net_hook()`), into arrays that exist without IPv6 and are never run.
* Image / kernel in flash / `root.squashfs` / kernel in RAM: 5569 / 1927 / 3608 / 6460 → **5377 / 1793 / 3536 / 6018 KiB** (−134 KiB of kernel flash and −442 KiB of kernel RAM with `-O2`; the preliminary research measured −108 / −367 at `-Os`). The image loses `odhcp6c`, `odhcpd-ipv6only` and `luci-proto-ipv6`; busybox and dnsmasq build without IPv6.
* A trap of the build: `luci-light`, built before with IPv6, kept pulling `luci-proto-ipv6` into the image (its dependency is `+IPV6:luci-proto-ipv6`); `build.sh` rebuilt it ([section 3](#3-size-of-the-kernel)).
* Another one, found on 2026-11-02: busybox without IPv6 has no `ping6` and `traceroute6`, but its install directory kept their links, so every image from this step on had both, answering `applet not found`. busybox installs a link for every applet and never removes one; `build.sh` now compares the busybox links of the image with `busybox.links` of the build and rebuilds busybox. The image cannot check this itself: OpenWrt builds busybox without its `busybox` applet, so `busybox --list` prints nothing.

**Decision reversed (2026-11-03): IPv6 is back, in the kernel and the programs.** The firmware is published, and some of its users get IPv6 from their ISP while others do not. Option A also needed a kernel patch, an edit of the build system and workarounds elsewhere: travelmate's `trm_wwan6`, the IPv6 listen addresses of uhttpd and the IPv6 rules removed on the first boot. Each of them had to be ported with every release. All of it is gone. The kernel fragment builds in what the patch did without (`NF_DEFRAG_IPV6`, `NF_LOG_IPV6`, `NF_REJECT_IPV6`, `NFT_FIB_IPV6`, `NFT_REJECT_IPV6`, like their IPv4 counterparts), and the image gets back `odhcp6c`, `odhcpd-ipv6only`, `luci-proto-ipv6` and the IPv6 of busybox. IPv6 alone cost +192 KiB of image, +134 KiB of kernel flash, +72 KiB of `root.squashfs` and +442 KiB of kernel RAM (the measurement above). The whole step of 2026-11-03 (IPv6, the VPNs as modules, AmneziaWG and DoH with HTTP/2 of libcurl, [sections 13](#13-vpn-wireguard-and-amneziawg) and [14](#14-encrypted-dns-doh)), `o2` profile, KiB:

| Image | Free for settings | Kernel in flash | `root.squashfs` | Kernel in RAM | Modules in the image |
|---|---|---|---|---|---|
| 5889 → **6401** | 1727 → **1215** | 1823 → 1934 | 4045 → 4431 | 6105 → 6483 | 9 → 16 (1086 → 1229) |

On the QEMU bench: a ULA by SLAAC in the LAN, ping to the router over IPv6, `odhcp6c` on `wan6` (the bench now creates `wan6` the way `config_generate` does) and the IPv6 rules of fw4 *(bench)*. `MemAvailable` 90 s after boot: 15564, 15864 and 18760 kB in three runs (one image varies by about 3 MB between runs); the bench passes 53 checks.

## 5. Compiler and flags

The speed of routing and Wi-Fi is set by kernel code (NAT, mac80211, mt76), so the main lever is `-O2` for the kernel, not the flags of the programs.

* **GCC.** OpenWrt 25.12.6 builds GCC 14.3.0 by default and offers 15.2.0 (`CONFIG_GCC_USE_VERSION_15`). 15.3.0 is in OpenWrt main through three commits; with `git cherry-pick -x` in this order they applied to `v25.12.6` without conflicts on 2026-10-31: `d8458334a7` ("toolchain: gcc: drop 110-Fix-MIPS-PR-84790.patch", fixed in GCC 15.1), `59c07e6053` ("toolchain/gcc: use configure option to disable TM clone registry"), `97424f9c86` ("toolchain: gcc: update GCC 15 to 15.3.0"). GCC 16 is not in OpenWrt.
* **Flags for the 24KEc.** OpenWrt builds the programs with `-mips32r2 -mtune=24kc`. In GCC's table of MIPS cores (`gcc/config/mips/mips-cpus.def`) `24kc`, `24kec` and `34kc` share the pipeline model `PROCESSOR_24KC`; `-march=24kec` only adds the DSP ASE, which the compiler rarely uses. `-mno-branch-likely` stays (OpenWrt turns branch-likely off).
* **The DSP ASE** (2026-11-02). `-march=24kec` turns on `-mdsp` (DSP ASE revision 1: SIMD on 2 × 16 or 4 × 8 bits of a register, saturating and fixed-point arithmetic, three more multiply accumulators, indexed loads). The kernel of this SoC declares the DSP (`cpu_has_dsp 1` in `mach-ralink/mt7620/cpu-feature-overrides.h`) and saves its registers at every task switch anyway, and the 24KEc of QEMU has it too (`ASEs implemented: mips16 dsp`). Compiled with the image's own compile commands and only the optimisation and ISA flags replaced, GCC 15.3.0 used just the indexed loads `lwx` and `lbux` and, at `-O2`, a few multiply-accumulates on `$ac1`: libucode has 146–151 DSP instructions and 0.3 % less code, the bignum, ECP, SHA-256 and AES code of mbedtls 323–355 and 0.4–0.6 % less. MIPS16 code does not change at all (no DSP in MIPS16 mode). No source of the 113 packages the build compiles tests `__mips_dsp`, so nothing has DSP code of its own. A speed gain is expected well below 1 %; the risk is a code path of GCC that OpenWrt, which builds every MIPS target without `-mdsp`, rarely exercises.
* **The kernel ignores `CONFIG_TARGET_OPTIMIZATION`**: it uses `-march=mips32r2 -mtune=34kc` from `arch/mips/Makefile` (the same pipeline model), and `-O2` comes from `CONFIG_KERNEL_CC_OPTIMIZE_FOR_PERFORMANCE` (`small_flash` defaults to `-Os`). mac80211 and mt76 are built with the kernel's flags.
* **MIPS16.** `CONFIG_USE_MIPS16` (`toolchain/Config.in`, default `y`) builds the programs with `-mips16 -minterlink-mips16`: smaller, slower. A package opts out with `PKG_BUILD_FLAGS:=no-mips16` (`include/package.mk`).

Full builds, one package set and one trimmed kernel; each step adds one change to the one before:

* **GCC 15.3.0 instead of 14.3.0:** kernel −5 KiB, squashfs −21 KiB, kernel RAM −25 KiB. Measured again in this tree (2026-11-01) on the official package set (`reference.config` with GCC 15.3.0): image 5889 instead of 5953 KiB, kernel in flash 2067 instead of 2075 KiB, `root.squashfs` 3804 instead of 3828 KiB, kernel in RAM 7022 instead of 7056 KiB. With `ALL_KMODS` the out-of-tree USB Wi-Fi driver `kmod-rtl8812au-ct` does not build with GCC 15 (as in the AX3200 build); the seed leaves it out.
* **Kernel `-O2`:** +270 KiB of kernel and +62 KiB of Wi-Fi modules in flash; kernel RAM 5884 instead of 5028 KiB (+856), modules 1268 instead of 1100 KiB. This is the code that does NAT and Wi-Fi.
* **Programs without MIPS16:** +64 KiB at `-Os`; with `-O2 -march=24kec` another +233 KiB. Unpacked, busybox grows from 312 to 524 KiB, wpad from 612 to 1072 KiB, libucode from 134 to 178 KiB: about 0.7 MB more RAM for the code of the running programs (1774 instead of 1062 KiB for these three).
* **LTO + gc-sections:** −5 KiB without MIPS16; with MIPS16 the shared libraries fail to link (`R_MIPS16_26 … recompile with -fPIC`; bzip2 and elfutils needed `no-lto`).

| | Official 25.12.6 | `-O2` everywhere | Programs `-Os` + MIPS16 |
|---|---|---|---|
| Image, KiB | 5952 | 5184 | 4928 |
| Free for settings, KiB (of 7616) | 1664 | 2432 | 2688 |
| Kernel in RAM, KiB | ≈ 6900 | 5884 | 5884 |
| Modules in RAM, KiB | 1968 (73 modules) | 1268 (22) | 1268 (22) |
| Code of wpad + busybox + libucode, KiB | 1393 (+ libmbedtls 624) | 1774 | 1062 |

These builds had no IPv6 in the kernel, like option A of [section 4](#4-ipv6) (whose patch adds the `inet` code back, a few KiB). The `-O2` image was measured with LTO; without it squashfs is ≈ 5 KiB larger. The first release adds to it: travelmate with `curl` and `ca-bundle` (up to 692 KiB with `mbedtls`, less without TLS), the Russian translation of LuCI, `igmpproxy` and `udpxy`; it saves `ip-tiny`, `urngd` and the trimmed busybox applets. All of this is measured with the first builds.

The programs do not route packets. Of them, the responsiveness of the web interface depends mostly on ucode, on which LuCI runs; users on 4pda reported LuCI pages that took 30–40 s to load on this router.

**The two profiles** (2026-11-02, `build.sh --profile`; the kernel is the same in both, 1823 KiB in flash and 6105 KiB in RAM):

| | `hybrid` | `o2` |
|---|---|---|
| Flags of the programs | `-Os -mips32r2 -mtune=24kc`, MIPS16; ucode without | `-O2 -march=24kec -mtune=24kec`, no MIPS16 |
| Image, KiB | 5633 | 5889 |
| Free for settings, KiB (of 7616) | 1983 | 1727 |
| `root.squashfs`, KiB | 3779 | 4045 |
| Programs and libraries unpacked, KiB | 6639 | 8524 |
| busybox / wpad / dnsmasq / pppd, KiB | 305 / 820 / 223 / 239 | 513 / 1274 / 347 / 334 |
| netifd / procd / uhttpd / rpcd / libucode, KiB | 146 / 79 / 50 / 46 / 186 | 210 / 99 / 58 / 58 / 182 |
| hostapd / wpa_supplicant resident on the QEMU bench, kB | 3012 / 2648 | 3224 / 2792 |
| QEMU bench | 43 PASS | 43 PASS |

* ucode without MIPS16 costs 10 KiB of `root.squashfs` (3769 → 3779 KiB); libucode grows from 134 to 186 KiB unpacked.
* OpenWrt's own projects set `-Os` in their `CMakeLists.txt` (`ADD_DEFINITIONS(-Os …)`: ucode, libubox, uci, rpcd, uhttpd, netifd, ubox, cgi-io, jsonfilter, fstools, lucihttp, rpcd-mod-luci; mbedtls too), and it comes after the flags of the profile. In `o2` they are built at `-Os` without MIPS16, so the LuCI stack is not `-O2` in either profile; `-O2` reaches busybox, wpad, dnsmasq, pppd, curl, json-c and the like.
* `o2` leaves about as much free flash as the official image (1664 KiB), and its programs take 1.9 MB more unpacked: more page cache for the same work, which squashfs has to decompress again whenever memory runs short.
* `MemAvailable` 90 s after boot varied by about 3 MB between runs of one image on the bench, more than the difference of the profiles.

**Decision:** GCC 15.3.0, kernel `-O2`, no LTO. Two profiles of the programs are built: `o2` (`-O2 -pipe -mno-branch-likely -march=24kec -mtune=24kec`, no MIPS16; the recommendation of the preliminary research) and `hybrid` (`-Os` with MIPS16, ucode with `no-mips16`; the proposal of the review). The DSP ASE only in `o2` (2026-11-02): it changes no MIPS16 code. The release takes the one that wins the A/B on the router: the LuCI timing of `tests/router/luci-bench.sh` and in a browser, `MemAvailable`, the time of a WPA3 connection and of the boot. The forwarding path is the kernel's and the same in both.

## 6. Wi-Fi driver fixes from mt76 master

OpenWrt 25.12.6 pins mt76 at `39c960c3` (`PKG_SOURCE_DATE:=2026-03-19`, `PKG_RELEASE:=3`) with 97 patches. `openwrt/mt76` master was at `0936617` on 2026-11-01, 470 commits later. Master targets Linux 6.18 and its mac80211, so the version cannot be raised as a whole; fixes are taken as patches, as in the AX3200 build.

**Selection (2026-11-01).** All 470 commits were checked for the code this router runs: `mt7603` (2.4 GHz, MT7628), `mt76x02` and `mt76x2` without the USB parts (5 GHz, MT7612E), and the common mt76 code these drivers actually call. 22 commits qualify. In upstream order they all applied without conflicts on top of `39c960c3` and the 97 patches of 25.12.6 (an mt76 tree rebuilt from the package; compiling them is part of the first build):

| What it fixes | Chip | Commits (`openwrt/mt76`) |
|---|---|---|
| Clients in power save (phones, U-APSD): traffic stuck until they woke up, retry storms, losses | MT7628 (`mt7603`) | `baac541` fix U-APSD service period termination · `56fe4e0` tell mac80211 when the PS queue has run empty · `276db24` restore hardware PS buffering after a service period · `5504bac` file buffered frames under the TID reported to mac80211 · `a374cac` don't drop short frames looped back on PS entry |
| A beacon SKB leak, a NULL dereference of the global WCID, MCU response length | MT7628 | `099844e` free beacon SKB on error · `c50f17e` initialize global station WCID · `5e697c3` validate MCU response length |
| Frames to sleeping clients dropped by the hardware; a race on the drop mask | MT7612E (`mt76x02`) | `4af6beb` clear the wcid drop mask for all powersave responses · `f75d4f0` serialise wcid drop mask updates |
| The BE queue stopped under load | MT7612E | `0d218af` keep A-MSDU subframe buffers at even addresses |
| Clients dropped broadcasts after a watchdog recovery; a kernel panic in that recovery | MT7612E | `558c6ae` sync the group key PN before a restart · `8127e3f` keep stations registered during watchdog recovery |
| Input checks | MT7612E | `f5dc427` report rx FCS errors to mac80211 · `0789c43` validate TX-status rate index before mac80211 handoff · `27a48ee` validate RX padding before use |
| Power save, races and leaks in the common code | both | `cf8a369` set the EOSP bit in the QoS header of the last released frame · `247c4d9` honour the more-data flag when releasing buffered frames · `0401792` fix out-of-bounds access in mmio copy helpers · `8f69e21` fix unlocked wcid check in mt76_tx_status_skb_add() · `b1bc93f` fix wcid->pktid corruption in mt76_wcid_cleanup() |
| **The station RSSI average was always 0** | both | `ed62359` feed the station RSSI average from the chain signals |

* **`ed62359`** matters for range: since `4550fb9e9810` the drivers no longer set `status->signal` before `mt76_check_sta()`, so the RSSI average was fed zeros. mt76x2 then set the gain of its receiver (AGC) from the −75 dBm fallback, and the dynamic sensitivity of mt7603 stayed at its default. Its author measured −75 → −54 dBm for the AGC input of an MT7662E and 0 → −41 dBm for the station average of an MT7603E on a TP-Link Archer XR500v.
* **An own fix for mt7603.** The same commit notes that "a separate bug" keeps the mt7603 sensitivity at 0; master has no fix. Since `f7e9be8` (2020, "add upper limit for dynamic sensitivity minimum receive power") `mt7603_false_cca_check()` only raises the sensitivity when `dev->sensitivity < -100 + dev->sensitivity_limit`, i.e. below −72 with the default limit of 28. The initial value is 0 ("off"), for which the condition is false, so the dynamic sensitivity of the 2.4 GHz radio never starts. The fix: `!dev->sensitivity || dev->sensitivity < -100 + dev->sensitivity_limit`. It needs `ed62359`, since a zero RSSI average resets the sensitivity to 0 as well. On the MT7622 of the AX3200 the working dynamic sensitivity halved the time the 2.4 GHz radio considered the channel busy (31 → 15 %) and reduced ping loss; the threshold never goes above the weakest connected client's RSSI − 15 dB. To be tested, then submitted to openwrt/mt76.
* **Left out, as code this router does not run:** `7ff2f29` (`mt76_reset_device()` is only called by mt7915 and mt7996); `f8b59ca` and its prerequisite `9a46d8d` (`MT_DRV_HW_PS_BUFFERING`, not in 25.12 and not used by these drivers); `b94b75e` (`mt76_get_rate_power_limits()` is not called by them); `0898393` (only drivers with `MT_DRV_HW_MGMT_TXQ`); `e053e8c` (an EEPROM chip ID of EcoNet SoCs); `c5a3bd9` (the LED define bug came with `d2b01fbc329b`, which is not in the pin; the Wi-Fi LEDs of this router are GPIO LEDs with `phy0tpt`/`phy1tpt` triggers); `7825972` (`CONFIG_PCIEASPM` is off, so `mt76_pci_disable_aspm()` writes the register itself); `8e1889a` (only wcid ranges with an offset, used by WED); `db39c8d`, `047558e` (USB and SDIO); commits to `channel.c` and `scan.c` (these drivers use the chanctx emulation of mac80211 and software scanning); MLO, WED, NPU, RRO and connac commits.
* **Already among the patches of 25.12.6:** `4979504`, `41b98d7`, `2ab6498`, `03644ac`.
* **Against the preliminary research:** it carried `7ff2f29`, missed `ed62359`, and expected `8127e3f` and `f8b59ca` to need adaptation. `8127e3f` applies in upstream order; `f8b59ca` fixes a feature these drivers do not have. Its review named `16f56d6` and `a89e409`, which do not exist in `openwrt/mt76`; the commit it meant by "wake queues after reconfig" is `82c085f`, already part of the 25.12 pin. It also swapped several descriptions (the more-data flag is `247c4d9`, not `5e697c3`; the `of_node` leak is `b94b75e`, not `7ff2f29`).
* Hypothesis: the power save bugs on 2.4 GHz could explain a report on 4pda (February 2023, 22.03): speed tests fine, downloads below 10 Mbit/s. Only the router can tell.

**Decision:** the 22 commits and the own fix as `package/kernel/mt76/patches/03xx-*.patch` (each naming its upstream commit; `PKG_RELEASE` one higher than upstream's). Test the power save fixes with a phone, the sensitivity with a dev build that keeps debugfs. Done on 2026-11-02: `0300`–`0321` in upstream order, `0322` the own fix; they build for both targets, and the drivers load on the QEMU bench.

## 7. Wi-Fi client and access point (WISP)

* Both drivers allow a client and access points on one radio, on one channel only: `mt7603` up to 4 interfaces, `mt76x02` up to 8, both `num_different_channels = 1` (`mt7603/init.c`, `mt76x02_util.c` at `39c960c3`). The client needs `wpa_supplicant`, hence a `wpad-basic*` variant and not `hostapd-*` ([section 2](#2-size-of-the-programs)).
* On one radio every packet goes over the air twice and the throughput roughly halves. Receiving on one band and sharing on the other avoids this; the Ethernet ports do not limit this path, the CPU does (NAT, mac80211, mt76).
* When the upstream network disappears, `wpa_supplicant` scans the channels, and the access points of the same radio stop.
* Routed mode: the client interface goes into the `wan` firewall zone, then NAT works as usual. `relayd` is only needed for one subnet shared with the upstream router.
* **travelmate 2.4.9** (packages feed `093d551675`) handles uplink loss, switching between known networks and captive portals. It depends on `iwinfo`, `jshn`, `jsonfilter`, `curl`, `ca-bundle`, `rpcd`, `rpcd-mod-rpcsys`; `luci-app-travelmate` adds `luci-lib-uqr`. The preliminary research measured +692 KiB of squashfs with `curl`, `mbedtls` and `ca-bundle`. travelmate uses `curl` for its captive portal check, by default against `http://detectportal.firefox.com`; a libcurl without TLS (`LIBCURL_NOSSL`) keeps that check and drops `mbedtls`, only the login to HTTPS captive portals would fail. `ca-bundle` stays a hard dependency either way.
* travelmate recreates the client interface often; the interface returns to the fw4 flowtable with its own `ifup` ([section 8](#8-routing-acceleration-and-iptv)).
* **Automatic channel selection on 5 GHz** (the router, 2026-11-03): with `channel auto` hostapd scans for about 2 minutes after every start before the 5 GHz access point comes up, and logs `ACS: Survey for freq … is missing noise floor` hundreds of times. mt76x02 reports no noise floor in its survey (mt7615, mt7915, mt7921 and mt7996 do); OpenWrt's `470-survey_data_fallback.patch` of hostapd then assumes −95 dBm and logs each case, so the choice rests on the busy time alone, which the survey showed as 0 ms on the channels it listed. It chose channel 52. The default of the build stays a fixed channel 36 ([section 6](#6-wi-fi-driver-fixes-from-mt76-master) for the drivers).
* **Setup** (QEMU bench, 2026-11-02). travelmate stays idle until its Interface Wizard (LuCI, `/etc/init.d/travelmate setup`) has run: without `trm_iface` the service logs "please use the 'Interface Wizard'" and stops. The wizard turns travelmate on and creates `trm_wwan` (DHCP, metric 100) in the WAN zone, and with it `trm_wwan6` (DHCPv6 on `@trm_wwan`), which this image cannot run: netifd runs it as `none`, and LuCI shows "Unsupported protocol type" with a link to the package manager the image does not have. When `trm_wwan` exists already, the wizard only turns travelmate on (it still adds the name `trm_wwan6` to the WAN zone). Turned on without uplinks, travelmate does not scan (the radio loop of `f_main()` skips radios without uplinks unless `trm_autoadd` is on); it scans when the uplink is lost, and then the access points of that radio pause. A feed patch (2026-11-02) created `trm_wwan6` only with IPv6 in the kernel (`/proc/sys/net/ipv6`, the test `config_generate` uses for `wan6`) and added it to the zone only when it existed. With IPv6 back (2026-11-03, [section 4](#4-ipv6)) `trm_wwan6` runs, and the patch is gone; the bench runs the wizard.
* **WPA3** (2026-11-02). `wpad-basic-mbedtls` instead of `wpad-basic`, since `mbedtls` is in the image for libcurl anyway. The 5 GHz access point gets WPA2/WPA3 mixed mode (`sae-mixed`, PMF optional) where `hostapd -vsae` reports SAE; 2.4 GHz stays WPA2. The WISP client can now also join networks that are WPA3 only.
  * CPU: only a connection costs more, through the SAE handshake (P-256 arithmetic of mbedtls in hostapd). The traffic is CCMP in the hardware of both radios, as with WPA2. Of PMF, the unicast management frames use the hardware key; the group management frames (BIP-CMAC) are left to mac80211 in software (`mt7603_set_key()` and `mt76x02_set_key()` do not take `AES_CMAC`), and they are rare. The time of a handshake on the 575 MHz CPU is to be measured on the router.
  * Clients: WPA3 is mandatory for Wi-Fi certification since July 2020; Android 10, iOS 13 and Windows 10 1903 (with a driver that supports it) have it. Older devices, TVs and media players among them, often have WPA2 only, also on 5 GHz: WPA3 only would lock them out of 5 GHz, mixed mode lets them join with WPA2. A WPA2 handshake of such a device can still be attacked offline, so the password matters as before.
  * Risk: an attacker in range can make the router compute SAE with forged requests; hostapd answers with anti-clogging tokens beyond a few open handshakes.
  * QEMU bench (`mac80211_hwsim`): a WPA2 client and a WPA3-only client (`sae`) associate with a `sae-mixed` access point; `77_wireless` run with the bands of the router gives 2.4 GHz `psk2+ccmp` and 5 GHz `sae-mixed`. Memory of the running processes (`RssAnon` / `VmRSS` of `/proc/<pid>/status`; the kernel has no `smaps_rollup`): hostapd 456 / 2196 → 560 / 2888 KB, wpa_supplicant 412 / 2240 → 436 / 2588 KB (private / resident). Most of the growth is the code of mbedtls, file pages that both processes share and that the kernel can drop and read again from flash. `MemAvailable` 90 s after boot moved more than that between two runs of one image (15.2 and 18.4 MB), so it cannot show the difference. Rebooting with WPA2 or WPA3 on the access point and the client took the same time.

**Decision (2026-11-01):** travelmate with `luci-app-travelmate` and its translation instead of an own watchdog script, since it fits (the free space stays at about the official 1.7 MB in the worst case). Measure libcurl with and without TLS. Recommend receiving and sharing on different bands. Measured in the packages step: 598 KiB of `root.squashfs` with libcurl over mbedtls, without HTTP/2, zlib, FTP and `file://` ([section 2](#2-size-of-the-programs)); the image has 1983 KiB free.

## 8. Routing, acceleration and IPTV

**No hardware NAT, one core.** OpenWrt has no hardware flow offloading for this SoC: the Ethernet driver of ramips (`target/linux/ramips/files/drivers/net/ethernet/ralink/`) offers no `ndo_setup_tc` and no PPE support. Software flow offloading (`flow_offloading='1'`, `kmod-nft-offload`) is the fast path. With one core, packet steering and `irqbalance` have nothing to spread the load to.

| Unit | Available | State |
|---|---|---|
| Ethernet (`rt5350-eth`) | RX checksum offload, GRO (`napi_gro_receive`), BQL, 1024 DMA descriptors | on |
| Ethernet | TX checksum offload, scatter-gather, TSO, VLAN tag insertion | not enabled by the driver for this SoC (`hw_features = NETIF_F_SG \| NETIF_F_RXCSUM`; the kernel drops SG without TX checksums); whether the hardware has them is undocumented. The VLANs of `eth0.1`/`eth0.2` are tagged in software |
| Crypto | no crypto engine | WireGuard uses the MIPS assembler ChaCha20 and Poly1305 (`kmod-crypto-lib-chacha20/mips32r2`, `kmod-crypto-lib-poly1305/mips` in `crypto.mk`) |
| Wi-Fi, both radios | CCMP in hardware, A-MPDU, airtime fairness with AQL, management frame protection | on |
| Wi-Fi 5 GHz (MT7612E) | LDPC, TX/RX STBC, short GI 20/40/80, VHT MCS 0–9 2×2, TX A-MSDU | on: the wifi scripts enable what the driver advertises (`ldpc:1`, `tx_stbc:1`, `rx_stbc:3`, `short_gi_*:1`, `max_amsdu:1` in `mac80211.sh`) |
| Wi-Fi 2.4 GHz (MT7628) | STBC, short GI; no LDPC advertised; TX A-MSDU off on purpose (`max_tx_fragments = 1`, PSE hangs) | on as far as available |
| Beamforming | supported by the MT7612E, not implemented by `mt76x2` (nor `mt7603`) | not available |
| Kernel | no SMP, `PREEMPT_NONE`, `HZ=100`, no FPU emulation | as OpenWrt sets them |

**Candidates to measure** ([TODO.md](TODO.md#on-the-router)): `JUMP_LABEL` (off in OpenWrt, supported on MIPS: static keys of the packet path become patched no-ops instead of a memory read per packet); GRO on `eth0` on or off (without TX checksum offload merged packets are segmented and checksummed in software again); flow offloading coverage of a PPPoE WAN, WireGuard and the WISP client.

**Wi-Fi in the flowtable** (QEMU bench, 2026-11-02). Linux 6.12 removes a device from a flowtable when it goes away and never adds it back (`nf_tables_flowtable_event()` handles only `NETDEV_UNREGISTER`; 6.16 binds returning devices by name, "netfilter: nf_tables: Respect NETDEV_REGISTER events"). On the AX3200 the recreated access points (`wifi reload`, changed settings) dropped out until the next firewall reload, since with hardware offloading fw4 puts the ports of the bridge into the flowtable (`resolve_hw_offload_devices()`), and its build reloads the firewall from a hotplug script. With software offloading, the only kind this SoC has, fw4 puts the devices of the zones themselves into it (`resolve_offload_devices()`): `br-lan`, the WAN device, `pppoe-wan`, `wg0`, the WISP client interface. The access points are ports of `br-lan`, which a Wi-Fi restart does not recreate; their traffic takes the fast path at the ingress of `br-lan`. On the bench the flowtable held `{ "br-lan", "eth1" }` before and after `wifi down; wifi up`. A client interface in the WAN zone is recreated, but its `ifup` makes OpenWrt reload the firewall (`/etc/hotplug.d/iface/20-firewall`): in two restarts it was back about a second after its interface came up, before the client had associated. PPPoE and WireGuard return the same way.

**What the hardware cannot do** (a search of 2026-11-06 for patches and builds for these chips; [TODO.md](TODO.md#on-the-router) has the candidates it found):

* **No checksums, scatter-gather or TSO on transmit, no hardware NAT.** MediaTek's own Ethernet driver for its SDK (`raeth`, as kept in Padavan, [rt-n56u](https://github.com/andy-padavan/rt-n56u/tree/master/trunk/linux-3.0.x/drivers/net/raeth)) counts the MT7628 with the RT5350 as a "switch DMA engine" (`RAETH_SDMA` in `ra_compat.h`): RX checksums only, the TX checksum, scatter-gather, TSO and VLAN insertion are left out for it, as in OpenWrt's driver. Padavan's hardware NAT covers the MT7620 and MT7621, not the MT7628. The software path of this build is the only one.
* **No overclocking.** No documented way to run the MT7628/MT7688 above its 575–580 MHz was found.
* **The upstream DSA driver of the MT7628 switch** (Linux 7.2, 2026) is for a later kernel and has no bridge offloading; nothing to gain here.
* **Interrupt moderation exists upstream.** The mainline `mtk_eth_soc` driver, which supports the MT7628, moderates its interrupts dynamically through the PDMA delay interrupt (`e9229ffd550b`, net DIM; fixed for the MT7628 in `430bfe057612`). OpenWrt's `ralink` driver of this target writes 0 to `FE_REG_DLY_INT_CFG`: one interrupt per received batch.
* **No tuned build for this router** turned up; Padavan supports MT7628 boards with MediaTek's own Wi-Fi drivers on its 3.x kernel, which cannot be carried over to OpenWrt.

**SQM** is not among the requirements. The preliminary research expects that this CPU cannot shape 100 Mbit/s; this is not measured. On the AX3200 software flow offloading worked together with SQM.

**IPTV** (in the image from 2026-11-01 to 2026-11-06, decision below). Multicast routing (`KERNEL_IP_MROUTE`, an OpenWrt default) needs a proxy daemon in the image, since nothing can be installed later. ISPs that hand IPTV to a set-top box over its own VLAN need none, only the switch settings (LuCI → Network → Switch).

* `igmpproxy` (packages feed): the usual choice of the OpenWrt wiki and of the guides for routed IPTV; configured over UCI (`quickleave`, upstream `wan`, downstream `lan`), no LuCI page. Its package enables it with that configuration, and its init script then opens the firewall for IGMP and multicast from the WAN.
* `udpxy` (packages feed, `luci-app-udpxy` with a Russian translation): turns multicast into HTTP unicast for players on Wi-Fi, phones and TVs; disabled by its own configuration.
* **The configuration of the `igmpproxy` package does not work with the default LAN** (found on the QEMU bench, 2026-11-01): its upstream (`wan`) carries `list altnet 192.168.1.0/24`. igmpproxy assigns an IGMP report to the interface with the longest matching subnet among the own subnets and altnets of all interfaces, the first one on a tie (`getIfByAddress()` in `ifvc.c`); the LAN subnet of the upstream's altnet ties with that of `br-lan`, so the reports of LAN clients count as coming from the upstream and are ignored (`Membership report was received on the upstream interface`), and no stream is forwarded. With `altnet 0.0.0.0/0`, the usual IPTV setting (the sources of IPTV are rarely in the WAN subnet), a stream from the WAN reaches a LAN client. udpxy is not affected; it needs a firewall rule that accepts multicast UDP from the WAN to the router itself.
* `omcproxy` (base, `luci-app-omcproxy`): OpenWrt's own IGMPv3/MLDv2 proxy, rarely used for IPTV; its strength is IPv6.
* Multicast over Wi-Fi goes at a basic rate. OpenWrt turns on multicast-to-unicast for access points by default, but it only takes effect with IGMP snooping on the bridge (`igmp_snooping` of `br-lan`, off by default; `CONFIG_BRIDGE_IGMP_SNOOPING` is in the kernel).

**Decision:** software flow offloading on by default; the flowtable hotplug script of openwrt-ax3200 is not needed (2026-11-02, above); no packet steering, `irqbalance` or SQM. `JUMP_LABEL` and GRO by measurement. IPTV (2026-11-01): `igmpproxy` and `udpxy` with `luci-app-udpxy`, both off until IPTV is set up; left out on 2026-11-06 (below). The first-boot defaults (2026-11-02, `files/etc/uci-defaults/99-a5v4-defaults`) turn on flow offloading, disabled `igmpproxy` with its upstream `altnet 0.0.0.0/0` until 2026-11-06, and let the WAN zone and the global defaults drop instead of reject ([section 9](#9-kernel-hardening)).

**Decision (2026-11-06): no IPTV.** The owner: ISPs hand out their own routers and set-top boxes for IPTV; it comes back if users ask for it. Out: `igmpproxy`, `udpxy`, `luci-app-udpxy` with its translation, the first-boot default of `igmpproxy`, and the multicast routing of the kernel for IPv4 and IPv6 (`KERNEL_IP_MROUTE`, `KERNEL_IPV6_MROUTE`: nothing else in the image routes multicast). Measured against the image with GRO off (`o2`): the image 6401 → 6337 KiB (1279 KiB free for settings, 64 more), `root.squashfs` 4431 → 4390 KiB, the kernel 1935 → 1919 KiB in flash and 6484 → 6429 KiB in RAM (the code of multicast routing; the two programs were off and took no RAM).

* **Lost:** multicast IPTV of the ISP behind the router (a set-top box in routed mode, `udp://` playlists on a PC or TV) and udpxy for players on phones and TVs over Wi-Fi. With no package manager in the image, a user cannot add them.
* **Not affected:** a set-top box on its own VLAN or port (LuCI → Network → Switch), IPTV over the internet (the apps of ISPs and services), and multicast inside the LAN (mDNS, SSDP, DLNA, casting), which the bridge carries without routing.
* IGMP snooping of `br-lan` stays off, as OpenWrt has it: without streams from the WAN, multicast-to-unicast of the access points has little to carry.
* The QEMU bench checks that the kernel has no multicast routing and that no multicast from the WAN reaches a LAN client that joins a group; its checks of `igmpproxy` and `udpxy` stay for an image that carries them again, which also needs the `altnet 0.0.0.0/0` above.

## 9. Kernel hardening

**Threat model (2026-11-01):** attacks from the WAN and from Wi-Fi clients that are not authorised; the LAN and authorised Wi-Fi clients are trusted. Both untrusted sides reach kernel code (frame parsing in mac80211/mt76 before authentication, the network stack, PPPoE, WireGuard) and services that drop root (wpad runs as `network`, dnsmasq as `dnsmasq`), where the kernel is the second barrier. Fixes in [section 6](#6-wi-fi-driver-fixes-from-mt76-master) of out-of-bounds accesses in RX parsing and copy helpers show the kind of bug this covers.

| Option (OpenWrt default for ramips) | What it does | On the forwarding path |
|---|---|---|
| `STACKPROTECTOR` (kernel, regular) | a canary in functions with local buffers stops a stack overflow | slightly |
| `FORTIFY_SOURCE` (kernel) | bounds checks in `memcpy`/`strcpy` and the like | barely (mostly at compile time) |
| `HARDENED_USERCOPY` | bounds checks of copies between programs and the kernel | no (only for traffic to the router itself) |
| `SLAB_FREELIST_HARDENED` | obfuscated freelist pointers of the slab allocator | slightly (every `sk_buff` allocation and release) |
| `SLAB_FREELIST_RANDOM` | random order of objects in a new slab page | no |
| `SCHED_STACK_END_CHECK` | detects a kernel stack overflow on a task switch | no |
| Programs: stack protector, `_FORTIFY_SOURCE=1`, full RELRO | the same for wpad, dnsmasq, pppd, udhcpc, curl | no (programs do not forward packets) |

**PIE of the programs.** `small_flash` targets build without PIE by default (`PKG_ASLR_PIE_NONE` in `config/Config-build.in`), but the official buildbot sets `CONFIG_PKG_ASLR_PIE_REGULAR=y` (`config.buildinfo` of 25.12.6): the official image has PIE, and with it randomised code addresses, for the packages marked `PKG_ASLR_PIE_REGULAR:=1`, which are the network-facing daemons: wpad (`hostapd`), dnsmasq, pppd, dropbear, uhttpd, rpcd, ubus and procd. These are the programs the threat model exposes (DNS answers and PPP from the WAN, Wi-Fi frames before authentication). PIE costs flash and some speed of these programs on MIPS, none on the forwarding path: without it `root.squashfs` is 104 KiB smaller and the daemons take about 320 KB less RAM ([section 2](#2-size-of-the-programs)). The randomisation has 8 bits on this kernel (`ARCH_MMAP_RND_BITS=8`, 256 load addresses). procd stops restarting a service after 5 crashes within an hour (`respawn` 3600 5 5 in `procd.sh`), so guessing the address of dnsmasq, wpad, dropbear or uhttpd by crashing it fails; netifd restarts pppd without such a limit. **Decision (2026-11-02):** PIE stays; turning it off is in the space reserve ([TODO.md](TODO.md#space-reserve)).

**The WAN firewall** (2026-11-02, as in openwrt-ax3200). The WAN zone and the global defaults (interfaces in no zone) drop instead of reject: a closed port gives no answer at all. Only a policy still at the stock `REJECT` changes, so that a configuration kept from another firmware keeps its own choice. Ping from the WAN stays answered (OpenWrt's `Allow-Ping`, kept by openwrt-ax3200 too): what the WAN can reach is decided by the open ports, and there are none; ICMP errors that TCP needs (fragmentation needed) belong to existing connections and pass as related traffic either way; ping lets the ISP and the owner check the line. Also from openwrt-ax3200 (2026-11-02): `drop_invalid` (without it, packets that conntrack marks invalid leave the LAN through the WAN without NAT, with their LAN source address) and SSH only on the addresses of the LAN interface (`dropbear` `Interface 'lan'`); through WireGuard the router stays reachable at 192.168.1.1, which the bench checks. dropbear then starts only once the LAN has its address: on the bench 3–6 s after `lan` is up, instead of before it.

Not present anyway: KASLR and `VMAP_STACK` (off in the generic configuration), `STRICT_KERNEL_RWX` and kernel stack offset randomisation (not supported on MIPS); seccomp is left out ([section 10](#10-what-the-image-leaves-out)).

Cost: turning the kernel hardening off (usercopy, freelist, stack protector) saved 9 KiB of flash and 25 KiB of RAM in the test builds. On the AX3200 (aarch64, a partly different set) it saved ~5 % CPU per Gbit/s from LAN to Wi-Fi and nothing in the other direction, at the same throughput.

**Decision:** the hardening stays. An A/B on the router of `SLAB_FREELIST_HARDENED` and the kernel stack protector, the two options on the forwarding path, in the CPU-bound paths decides whether they go.

## 10. What the image leaves out

Decided on 2026-11-01. Against the official image of 25.12.6 for this router (the manifest of `ramips/mt76x8` plus `kmod-mt76x2`).

**By the requirements of the build:**

| Packages or options | What is lost |
|---|---|
| `apk-mbedtls`, `luci-app-package-manager` | installing and removing packages; System → Software. Any change of the set is a new firmware |
| `openwrt-keyring`, `usign` (no `SIGNED_PACKAGES`), `zlib` | nothing: keys and signature checks of package repositories; `zlib` was only needed by apk |
| ~~`odhcp6c`, `odhcpd-ipv6only`, `luci-proto-ipv6`, `kmod-nf-conntrack6`, `kmod-nf-log6`, `kmod-nf-reject6`, IPv6 in the kernel~~ | **taken back (2026-11-03):** IPv6 is in the image again ([section 4](#4-ipv6)) |
| Compatibility with the official kmods (`ALL_KMODS` off, `TRIM_UNUSED_KSYMS`) | no kernel module can be added without rebuilding the firmware |
| telnet | nothing: not in the official 25.12 image either |

**Proposed and approved:**

| Packages or options | What is lost |
|---|---|
| `attendedsysupgrade-common`, `luci-app-attendedsysupgrade` | updates through OpenWrt's online service, which would install plain OpenWrt anyway; updates go through System → Backup / Flash Firmware |
| `luci-ssl`, `px5g-mbedtls` | LuCI over HTTPS with a self-signed certificate; HTTP in the LAN, remote access through WireGuard |
| `uclient-fetch`, `libuclient`, `libustream-mbedtls` | `wget` on the router; `curl` of travelmate takes its place |
| ~~`wpad-basic-mbedtls` → `wpad-basic`~~ | **taken back (2026-11-02):** `mbedtls` came back with travelmate, and WPA3 costs 17 KiB with it ([section 7](#7-wi-fi-client-and-access-point-wisp)) |
| `libmbedtls`, `ca-bundle` | HTTPS on the router; `ca-bundle` returns with travelmate, `mbedtls` only with a TLS libcurl |
| `urngd` | little on Linux 6.12, whose `getrandom()` gathers jitter entropy itself; check the first boot |
| `procd-seccomp` and kernel seccomp | nothing today: no service of the image sets a seccomp policy (in the tree only `umdns` does). Measured (2026-11-01): 16 KiB of flash (kernel 4, `procd-seccomp` 12) and 12 KiB of kernel RAM. The plan of 2026-11-01 kept seccomp below 32 KiB, the approved list removes it; stays off (2026-11-02), since it would protect nothing |
| `rpcd-mod-rrdns` (if 8 KiB or more) | host names instead of addresses in LuCI's connection list |
| busybox applets `brctl`, `mkswap`, `swapon`, `swapoff`, `taskset` (2026-11-02, [section 2](#2-size-of-the-programs)) | nothing on this router: netifd makes the bridges, there is no swap and one core |
| `ip-tiny` not added: busybox `ip` | the full `ip` of iproute2 (`ip -br`, `ip -j`, finer `ip rule`/`ip route` options) |
| Kernel: debugfs and mac80211 debugfs | the Wi-Fi driver's diagnostics in `/sys/kernel/debug` (dev builds keep them) |
| Kernel: magic SysRq | emergency SysRq commands |
| Kernel: BPF and BPF JIT | nothing: no BPF program in the image |
| Kernel: multipath routing | load balancing over two uplinks (mwan3) |
| Kernel: POSIX ACL, GPIO sysfs, USB (`USB_SUPPORT`, `PHY_RALINK_USB`) | nothing: LEDs through `leds-gpio`, no USB port on the board. POSIX ACL went with `ALL_KMODS` (only optional file systems selected it) |
| IPTV (2026-11-06): `igmpproxy`, `udpxy`, `luci-app-udpxy`, `luci-i18n-udpxy-ru`; kernel: multicast routing for IPv4 and IPv6 | multicast IPTV of the ISP behind the router and udpxy for players; a set-top box on its own VLAN, IPTV apps and multicast inside the LAN stay ([section 8](#8-routing-acceleration-and-iptv)) |
| ~~Kernel: bridge VLAN filtering, xattr~~ | **kept (2026-11-01, against the approved list).** Bridge VLAN filtering: netifd always sets `IFLA_BR_VLAN_FILTERING` (0 or 1) when it creates a bridge (`system-linux.c`), and a kernel without the option answers `EOPNOTSUPP` (`br_vlan_filter_toggle()` stub): on the QEMU bench `br-lan` never came up and the LAN had no address. xattr of jffs2 and tmpfs: overlayfs keeps the opaque directories of the overlay in `trusted.overlay.opaque`; without xattrs on the upper file system it warns `failed to set xattr on upper`, and creating a directory where one of the squashfs was deleted fails with EIO (`ovl_set_opaque_xerr()` in `fs/overlayfs/dir.c`). jffs2 is the overlay, tmpfs that of the first boot |

**Kept:** the hardening ([section 9](#9-kernel-hardening)), bridge VLAN filtering and the xattrs of jffs2 and tmpfs (above). **Not added:** zram ([section 11](#11-zram)).

**Added to the official set:** `luci-light` pages for the firewall, PPP and WireGuard with `luci-i18n-base-ru` and `luci-i18n-firewall-ru`; `kmod-wireguard` (a module since 2026-11-03, loaded with a tunnel), `wireguard-tools`, `luci-proto-wireguard` (with `resolveip`); since 2026-11-03 `kmod-amneziawg`, `amneziawg-tools`, `luci-proto-amneziawg` with Russian ([section 13](#13-vpn-wireguard-and-amneziawg)) and `https-dns-proxy`, `luci-app-https-dns-proxy` with Russian ([section 14](#14-encrypted-dns-doh)); `travelmate`, `luci-app-travelmate`, `luci-i18n-travelmate-ru`, `iwinfo`, `curl` (libcurl over mbedtls, without zlib, FTP and `file://`; with HTTP/2 and `libnghttp2` since 2026-11-03, for DoH, [section 14](#14-encrypted-dns-doh)); `igmpproxy`, `udpxy`, `luci-app-udpxy`, `luci-i18n-udpxy-ru` until 2026-11-06 (IPTV, above). The packages step put them in on 2026-11-01 ([section 2](#2-size-of-the-programs)); `rpcd-mod-rrdns` stays (4 KiB, a dependency of `luci-light`).

## 11. zram

The official image runs without swap: `KERNEL_SWAP` is off for `small_flash` targets (`config/Config-kernel.in`), so the official `zram-swap` would not even start on this router. zram costs the swap code of the kernel, zram, zsmalloc and a compressor, in flash and RAM, plus CPU. It only helps under memory pressure: without swap the kernel then drops the page cache of squashfs and decompresses it from flash again, which may be what made LuCI slow on 4pda.

**Measured (2026-11-03).** zram built in (`SWAP`, `ZRAM`, `ZSMALLOC`, lzo-rle) with `zram-swap`, `hybrid` profile: kernel 1854 instead of 1823 KiB in flash and 6194 instead of 6105 KiB in RAM, `root.squashfs` +7 KiB (the script, `kmod-lib-lzo`, the swap applets of busybox come back), the image 5697 instead of 5633 KiB (1919 KiB free). zram can only take anonymous memory, and all programs together had 3.6 MB of it on the router (`AnonPages`, `o2`); the page cache of squashfs and the slab of the kernel (conntrack among it) stay in RAM either way. In the peak test of [section 12](#12-tests-on-the-router) `MemAvailable` did not go below 11 MB.

**Decision (2026-11-01):** the first build goes without zram. 2026-11-03: still without, pending a decision: it would cost 64 KiB of image and ~100 KB of RAM for at most a few MB under pressure the router has not shown.

## 12. Tests on the router

**Setup** (2026-11-03): the unit of the tests at a remote site, ISP over DHCP behind CGNAT, reached over WireGuard through a VPS; the `hybrid` image, then the `o2` image of the same code, each flashed with the settings kept and measured the same way. 2.4 GHz on channel 1 `HT20` (WPA2), 5 GHz on channel 52 `VHT80` (WPA3 only; `auto` during the boot below, fixed afterwards). Night, two clients on 2.4 GHz, none on 5 GHz. `tests/router/router-bench.sh` and `tests/router/luci-bench.sh` over SSH, the median of 3 runs of each program test; WireGuard with 20 MB through busybox `nc` to a host behind the VPS.

| | `hybrid` | `o2` |
|---|---|---|
| `MemAvailable`, kB: program bench at 22 min / during the LuCI runs | 15 936 / 18 328–19 288 | 14 328–14 896 / 13 624–15 692 |
| Private memory: hostapd / wpa_supplicant / netifd / rpcd / dnsmasq / uhttpd / procd, kB | 576 / 428 / 628 / 648–692 / 224 / 164 / 220 | 568 / 440 / 616 / 624 / 232 / 224 / 208 |
| Resident (with the shared code): hostapd / wpa_supplicant / dnsmasq, kB | 3040 / 2596 / 1284 | 3324 / 2776 / 1424 |
| Idle CPU over 30 s | 97.8 % | 98.6 % |
| busybox: `ash` loop 20 000 / exec 200 × / `gzip` 4.6 MB / `sha256sum` 3 × 4.6 MB, s | 1.33 / 1.09 / 8.34 / 4.23 | 1.05–1.10 / 1.09 / 6.37–6.51 / 1.71 |
| ucode: loop 200 000 / JSON 3000 objects × 5, s | 3.02 / 1.74 | 2.99 / 1.49–1.50 |
| `jsonfilter` 200 × / `ubus call` 150 × / `uci show` 200 × / `wg genkey \| pubkey` 100 × / `nslookup` 200 ×, s | 2.05 / 1.83 / 1.70 / 1.92 / 1.34 | 1.92–1.93 / 1.82–1.83 / 1.66–1.68 / 1.38 / 1.35 |
| LuCI: Overview HTML / login page / static `luci.js`, ms | 198 / 228 / 7.2–7.7 | 194–195 / 225 / 7.2–7.8 |
| LuCI ubus batches: Overview (21 calls) / Wireless (11) / Firewall (5), ms | 1146–1151 / 274–277 / 62–63 | 1131–1136 / 250–256 / 57–59 |
| Boot, first after sysupgrade, s: preinit / WAN port link / procd init / modules / LAN bridge / wg0 / WAN / 2.4 GHz / 5 GHz | 10.3 / 25.2 / 39.3 / 48.5 / 89.0 / 93 / 98 / 100.4 / 133.9 (ACS) | 9.7 / 21.9 / 35.7 / 43.8 / 78.1 / 81 / 86 / 87.1 / 97.6 |
| WireGuard through the VPS, router sends / receives (CPU busy) | 25.9–26.9 Mbit/s (65–73 %) / 19.4–23.2 Mbit/s (64–71 %) | 25.2–25.9 Mbit/s (70–71 %) / 18.8–22.5 Mbit/s (63–74 %) |
| Image / free for settings, KiB | 5633 / 1983 | 5889 / 1727 |

* The three LuCI runs differ by less than 1 %, the program tests by 1–2 %.
* **`luci getFeatures` takes 778 ms**, two thirds of the Overview batch: the rpcd plugin of LuCI runs `hostapd -v<feature>` and `wpa_supplicant -v<feature>` for 13 features each and `dnsmasq --version`, 27 starts of a program. The browser keeps the result for the session (`probeSystemFeatures()` in `luci.js`), so it costs the first page after login. Of the other calls `luci-rpc getWirelessDevices` takes 152 ms and `getHostHints` 99 ms; each of the rest 13–36 ms (with the start of the `ubus` client, about 12 ms).
* **WireGuard**: the CPU was not saturated in either direction, so the path through the VPS limited it, not the router.
* **5 GHz at boot**: 34 s after 2.4 GHz with `channel auto` (ACS, [section 7](#7-wi-fi-client-and-access-point-wisp)); with a fixed channel the radio needs no scan.
* **Wi-Fi** (60 s at night): busy 6.1 % on channel 1, 0.4 % on channel 52. TX power 22 dBm on both radios, the maximum of the chips (`iwinfo txpowerlist`); PA would allow 36 dBm EIRP. Clients −57 dBm (1×1, MCS 7, 72 Mbit/s) and −65 dBm (2×2, MCS 15, 144 Mbit/s), 126 and 450 TX retries and 2 failures in 24–30 minutes.
* **Channel scan** (3 scans per band): 18 networks on 2.4 GHz, the strongest −64 dBm on channel 1 and −65 dBm on channel 8; least interference on channel 13, then 11. On 5 GHz two networks of one device on channel 44 (−75 dBm), the blocks 52–64, 100–144 and 149–165 empty. mt7603 reports busy times in its survey, mt76x2 reports 0 ms off the operating channel.

**Peak load** (`o2`, 32 min after boot): a 6 MB file in `/tmp` (the size of a sysupgrade image), 2000 DNS lookups of unique names through dnsmasq (3483 conntrack entries), LuCI load at the same time. `MemAvailable` 19.2 MB before, at least 11.2 MB during (sampled continuously), 15.2 MB after the file was removed and 19.6 MB a few minutes later; the slab grew by 1.2 MB (about 350 bytes per conntrack entry), the page cache refaulted 602 pages. `vm.min_free_kbytes` is 8192 (OpenWrt's value for 64 MB): the kernel keeps 8 MB free for atomic allocations such as received packets, outside `MemAvailable`. The settings partition (`rootfs_data`) had 240 KiB of jffs2 in use for 26 KB of files.

**`o2` against `hybrid`:**
* Faster where busybox and the libraries do the work: the `ash` loop by 18–21 %, `gzip` by 22–24 %, `sha256sum` by 60 %, `wg genkey | pubkey` by 28 %, JSON in ucode by 14 % (json-c is `-O2` there), `jsonfilter` by 6 %. ucode itself, `ubus`, `uci`, `nslookup` and starting a program are the same: OpenWrt's own projects stay at `-Os` ([section 5](#5-compiler-and-flags)), and the kernel does most of the work of a start.
* LuCI 1–2 % faster on the Overview, 7–9 % on the Wireless and Firewall pages.
* The boot reached the LAN 11 s earlier (78 instead of 89 s) and 2.4 GHz 13 s earlier: init scripts run on busybox `ash`. Both were the first boot after a sysupgrade; `o2` has a smaller settings partition to erase.
* WireGuard, the forwarding path and idle CPU are the same.
* Costs: 256 KiB of flash, and 1–3.5 MB less `MemAvailable` (the private memory of the daemons is the same; their larger code takes more of the page cache).

**Decision (2026-11-03):** `o2`.

**After the IPv6, VPN and DoH step** (2026-11-03): the `o2` image of this step (6337 KiB), flashed with the settings kept. The settings come from the build without IPv6, so they have no `wan6`, no `ula_prefix` and no IPv6 rules of the firewall, and IPv6 was not tested on the router. Same methods as above; the program bench at 22 min:

| | `o2` before | `o2` after the step |
|---|---|---|
| `MemAvailable`, kB: program bench / LuCI runs | 14 328–14 896 / 13 624–15 692 | 18 028 / 16 016–17 272 |
| busybox `ash` / exec / `gzip` / `sha256sum`, s | 1.05–1.10 / 1.09 / 6.37–6.51 / 1.71 | 1.09 / 1.07 / 6.81 / 1.77 |
| ucode loop / JSON, `jsonfilter`, `ubus call`, `uci show`, s | 2.99 / 1.49–1.50, 1.92–1.93, 1.82–1.83, 1.66–1.68 | 3.00 / 1.52, 1.92, 1.81, 1.67 |
| `wg genkey \| pubkey` / `nslookup` 200 ×, s | 1.38 / 1.35 | 1.50 (1.40–1.77) / 1.47 |
| LuCI: Overview HTML / ubus batches Overview, Wireless, Firewall, ms | 194–195 / 1131–1136, 250–256, 57–59 | 197 / 1097, 264, 59 |
| WireGuard through the VPS, router sends / receives (CPU busy) | 25.2–25.9 Mbit/s (70–71 %) / 18.8–22.5 Mbit/s (63–74 %) | 25.4–26.7 Mbit/s (68–76 %) / 23.4–23.9 Mbit/s (78–83 %) |
| Boot: preinit / WAN port / procd / modules / LAN bridge / wg0 / WAN / 2.4 GHz / 5 GHz, s | 9.7 / 21.9 / 35.7 / 43.8 / 78.1 / 81 / 86 / 87.1 / 97.6 | 10.2 / 21.9 / 34.6 / 43.5 / 81.5 / 93 / 101 / 102.8 / 122.6 |

* **Programs and LuCI** as before, within 1–5 %. `nslookup` of busybox with IPv6 asks for A and AAAA. One run of `wg genkey` was slow.
* **Memory:** `MemAvailable` is higher than before, by 2–3.5 MB, although the kernel takes 378 KiB more and two DoH proxies run. On the QEMU bench one image varies by about 3 MB between boots ([section 4](#4-ipv6)), so this is no gain of the step.
* **The VPN modules:** `wireguard` loaded when netifd brought up `wg0`, together with `chacha_mips` and `poly1305_mips` (`poly1305-mips`, `xchacha20-mips` in `/proc/crypto`). A test interface `ip link add … type amneziawg` loaded `amneziawg` (77 824 bytes) and took the obfuscation options (`awg set … jc 4 … h4 …`); after `ip link del` the module unloaded. With the module, WireGuard receives faster than before at the same CPU per Mbit/s (about 3.4 % against 3.3 %). The path through the VPS still limits it: the CPU is not saturated.
* **DoH** answered from the first lookup:
  * `nslookup` through dnsmasq of `openwrt.org`, `example.com` and `ya.ru` took 70–80 ms, including the start of `nslookup`;
  * the router sent no DNS to the WAN (no conntrack entry to port 53), only HTTPS to Cloudflare (`104.16.249.249`, `172.64.152.106`) and Google (`8.8.8.8`);
  * the backup of the server list stayed `''` (the feed patch).
* **Found: DoH over HTTP/1.1.** libcurl had no HTTP/2:
  * every request logged `Setting HTTP/2 version failed with 1: Error`: 20 lines in the first two minutes, 399 in the first hour. https-dns-proxy asks for HTTP/2 by default;
  * a burst of 40 parallel lookups of unique names ran first while the proxies had only 3 connections open: 7 were answered in 11.7 s, the rest timed out, and the proxies opened 8 new TLS connections;
  * the second burst, on the open connections, got all 40 answers in 3.0 s and opened 10 more connections;
  * an instance started with `-x` (HTTP/1.1 asked for) logged nothing.

  libcurl is built with HTTP/2 again ([section 14](#14-encrypted-dns-doh)).
* **With HTTP/2** (the image with HTTP/2, 6401 KiB, flashed the same way):
  * no error in the log, and each instance keeps one TLS connection (2 in all);
  * bursts of 40 lookups got all 40 answers in 1.94, 1.43 and 1.30 s, and a burst of 100 got all answers in 4.56 s, with no new connection;
  * after the bursts an instance took 608–616 kB private and about 2.25 MB resident. `MemAvailable` was 17.6 MB at 3 min and 22.1 MB after the tests;
  * the router sent no DNS to the WAN. The only port 53 flows were IPv6 ones inside the router and from a LAN client to the router's link-local address.
* **IPv6 on the unit** (2026-11-03). The settings of a fresh install were added by hand, after a backup of the configuration and with a guard that would have restored it and rebooted unless access was confirmed within 5 minutes:
  * `wan6` (`dhcpv6` on the device of `wan`), `ip6assign 60` of the LAN and a ULA prefix, generated as `12_network-generate-ula` does (netifd does not resolve `ula_prefix 'auto'` itself, the first-boot script does);
  * `wan6` in the WAN zone and the four IPv6 rules of `/rom/etc/config/firewall`; the DHCPv6 and RA settings of the LAN were there already, added by odhcpd's own first-boot script.

  Results:
  * the LAN got its ULA (`fd…::1/60`), and fw4 has the IPv6 rules;
  * the ISP offers no IPv6 on this line. Temporary nft counters showed that `odhcp6c` sent router solicitations and 7 DHCPv6 Solicits, while in 75 s no router advertisement, neighbour message or DHCPv6 reply came back. `wan6` stays pending, as on the official image with such an ISP;
  * DoH, `wg0` and the access through it were unaffected;
  * `/proc/net/dev_snmp6` and the ICMPv6/UDPv6 counters of `/proc/net/snmp6` stay at 0 on this kernel even for packets that nft counts, so nft counters are the way to see IPv6 traffic here.

  IPv6 from an ISP that offers it remains untested on the router.

**Boot time** (2026-11-03). Two first boots after a sysupgrade had shown the WAN 13–15 s and Wi-Fi 15–32 s later than the `o2` image before the step, with the LAN as early as before. The router was rebooted 15 times (normal reboots, the image with HTTP/2) with different services off, timed from `logread` mapped to the kernel's uptime. Some boots ran a profiler (a temporary init script at `S01`):
* first the processes and the CPU counters every 2 s;
* then the state and the system call of the Wi-Fi setup processes (`/proc/<pid>/syscall`; this kernel has no `wchan`: no `KALLSYMS`);
* then the memory and the page cache counters;
* then the ubus events.

| Boots | odhcpd | WAN up, s | 2.4 / 5 GHz AP, s | Wi-Fi setup restarted |
|---|---|---|---|---|
| 8 | enabled (`S35`, one at `S99`) | 86–117, median ~100 | 106–185 / 118–194 | 7 of 8 |
| 4 | disabled | 79–91, median ~84 | 86–143 / 92–155 | 0 of 4 |
| `o2` before the step (one first boot) | — | 86 | 87.1 / 97.6 | — |

DoH and `wan6` made no clear difference: DoH starts its proxies after the radios.

* **The boot is bound by reading the flash.**
  * During the boot the CPU spent 76–90 % in the kernel and 10–24 % in user space.
  * Two `kworker/…H-kblockd` threads took 44 s of CPU in one boot, and the processes started by procd 46 s of system time.
  * Processes of the Wi-Fi setup sat in state D in `execve`, `mmap2` and `read`.
  * The flash is a GigaDevice GD25Q64 (`c84017`) driven at 10 MHz (`spi-max-frequency` of `mt7628an_tplink_8m*.dtsi`; most MT7628 boards of the tree use 40 or 50 MHz). `spi-mt7621` reads it without DMA.
  * `root.squashfs` uses blocks of 1024 KiB, OpenWrt's default for `SMALL_FLASH` (`CONFIG_TARGET_SQUASHFS_BLOCK_SIZE`). A page that is not cached costs the read and the xz decompression of a whole block.
  * By 205–213 s after the boot the kernel had read **46 MiB** of the 5.5 MiB rootfs partition with odhcpd disabled, and **77 MiB** with it (`/proc/diskstats`, `mtdblock4`). The page cache refaulted 787 and 2630 times.
  * `MemAvailable` stayed above 12.4 MB during the boot either way, so the reads are not caused by running out of memory.
* **odhcpd adds about 30 MiB of flash reads** at the time netifd sets up the radios: the daemon, its hooks and what its router advertisements set off on the LAN. With it the WAN came up 10–15 s later.
* **The Wi-Fi setup restarts** when its script runs out of time. netifd runs the setup scripts of the radios one after the other, each with a timeout of 30 s (`DEFAULT_SCRIPT_TIMEOUT` in `/lib/netifd/wireless-device.uc`). A script that does not finish in time is killed, the radio is torn down and set up again, and its access point comes up 30–80 s later. dnsmasq restarts at the same time. In 7 of the 8 boots with odhcpd, and in none without it, one radio went through this.
* **hostapd waits in `COUNTRY_UPDATE`** (the regulatory domain) for 0–47 s per boot, with or without odhcpd. This makes the rest of the spread.
* **Found: DNS in the clear after each boot.** The stop of https-dns-proxy at the shutdown restores the servers of dnsmasq, so after the next boot dnsmasq asks the ISP's DNS (`using nameserver` of `resolv.conf.auto`) until the proxies start, which can take minutes.

Candidates to make the boot faster are in [TODO.md](TODO.md#on-the-router); none is in the build yet.
* **The boot reached wg0 and the WAN 12–15 s later** than before, and the radios 16–25 s later; preinit, the WAN port, procd and the modules were on time. The ISP's DHCP took 19 s this time (`wan` setting up 15:07:17, up 15:07:36), while the Wi-Fi scripts waited on a busy CPU. One first boot after a sysupgrade each; a second boot would tell whether the step costs boot time.
* **The clock** started at the build time of the image, 7 min behind, and NTP corrected it. The DoH proxies started only after that, so this boot did not test an old clock.

**Wi-Fi throughput on 2.4 GHz** (2026-11-03, evening). A client measured 19 Mbit/s down and 40 up over Wi-Fi, against the 100 Mbit/s of the line over the cable. The client was a PC with a USB adapter of TP-Link (802.11n, one stream) on the 2.4 GHz network, channel 1, at −57 to −64 dBm (the two chains of the router hear it 8–12 dB apart). Measured while a download with many TCP flows ran to it, 20 s per run: the traffic of `phy0-ap0`, the channel survey, the TX counters of the station, `/proc/stat`.

| | `HT20` (3 runs) | `HT40` with `noscan` (2 runs) |
|---|---|---|
| To the PC, Mbit/s | 20.5 / 29.5 / 24.6 | 24.0 / 21.8 |
| Rate router → PC | MCS 4–6, 39–65 Mbit/s | MCS 2–3 at 40 MHz, 45–60 Mbit/s |
| Rate PC → router | MCS 7, 72 Mbit/s | MCS 7 at 40 MHz, 135–150 Mbit/s |
| Retries per packet / failed per 20 s | 0.36–0.54 / 13–64 | 0.72–0.76 / 354–746 |
| Channel busy / of it the router's TX | 88–90 % / 79–83 % | 89 % / 86 % |
| CPU idle | 43–57 % | 59 % |

* **The channel is the limit, not the CPU:** the router's own transmissions to the PC fill the air, and half the CPU is idle (sys 17–25 %, softirq 19–30 %). About half the conntrack entries of the download were offloaded. The upload is faster because the PC sends at MCS 7, while the router reaches the PC at MCS 4–6 with many retries.
* **`HT40` alone stays at 20 MHz:** hostapd's coexistence scan reports "20/40 MHz operation not permitted on channel pri=1 sec=5 based on overlapping BSSes". With `noscan` the radio runs at 40 MHz and the PC takes it, but the router's rate to the PC falls to MCS 2–3 and the losses grow tenfold, so the throughput is no better than at 20 MHz, and the wider channel takes the air of the neighbours on channels 2–8.
* **5 GHz** (channel 52, `VHT80`) was 1.5 % busy at the same time.
* **Found: mt7603 hangs when the radio is reconfigured under load.** The first switch `HT20` → `HT40` with `wifi up radio0`, while the download kept the channel 88 % busy, left `MCU message 08` (`MCU_EXT_CMD_CHANNEL_SWITCH`) unanswered. hostapd hung in state D, and the 2.4 GHz network stayed down until a reboot. The same switch with the download paused (twice) and the switch back `HT40` → `HT20` under load at 26 Mbit/s passed. See [TODO.md](TODO.md#on-the-router).

**Decision (2026-11-03):** 2.4 GHz stays at `HT20`. For more speed the client goes to 5 GHz or gets a better signal.

**A phone on 5 GHz and on 2.4 GHz** (the same evening, the download paused, speed tests of the phone; traffic, CPU and the station counters every 2 s, interfaces taken by name):

| Phone | Signal at the router | Rates (router → phone / phone → router) | Speed test at the router | CPU idle |
|---|---|---|---|---|
| 5 GHz, next to the router | −31…−43 dBm | VHT MCS 8–9, 2 streams / the same | 45–67 Mbit/s | 13–26 % |
| 5 GHz, a far room | −70…−81 dBm | VHT MCS 4–9, 1–2 streams / MCS 0–5 | 60–66 Mbit/s | 8–20 % |
| 2.4 GHz, next to the router | −28 dBm | HT MCS 12 / MCS 13 | 8–10 Mbit/s | 75–80 % |

* **5 GHz is bound by the CPU** at about 65–75 Mbit/s between Wi-Fi and the internet: the speed is the same near and far, and the CPU is nearly busy. With a download of another client at 30–35 Mbit/s the CPU was 40–50 % idle, about 1.5 % per Mbit/s of Wi-Fi traffic. The RSSI the router reports follows the distance, so the receiver of the MT7612E is not at fault. The speed test apps often ended with an error at this load, with no drops, invalid conntrack entries or disconnects on the router.
* **2.4 GHz to the phone is far below its link** with the CPU idle. A device in power save had 1802 failed and 17 629 retried frames for 26 KB of traffic, the PC (no power save) almost none, which points at the power-save handling of `mt7603`. Open: [TODO.md](TODO.md#on-the-router).

**The debug image on the router** (2026-11-05, at night, nobody at the site): `build.sh --dev`, flashed with the settings kept, tools from `tests/router/`.

* **RAM and the flash.** `MemTotal` 56 MB, `MemAvailable` 11–14 MB without tools (18–19 MB on the release image). With `perf` unpacked in `/tmp` (6 MB) it fell to about 5 MB, and a UDP test spent 95 % of the CPU in the kernel: 33 % in `__udelay` (`spi-mt7621` polls the controller with `udelay(1)` while it reads the flash at 10 MHz) and about 30 % in the LZMA decoder of squashfs readahead. The page cache had dropped the programs and read them again: 177 MiB of the 5.5 MiB rootfs in 25 minutes. Without `perf` the same test read nothing from the flash, and at idle the flash is not read at all. So memory pressure turns into flash reads at 10 MHz with 1 MiB blocks, at run time as at the boot; the boot candidates of TODO.md (the SPI clock, smaller squashfs blocks) bound both.
* **UDP from the router to a client on 2.4 GHz** (`udptest.sh`; an IoT device, −44 dBm, one stream, MCS 7 short GI): 45 Mbit/s on the interface, 0.07 retries per packet, the CPU 19 % idle (about 1.8 % per Mbit/s for the local send path). The profile (`kprof`) is flat: hashing for conntrack, the fair queueing of mac80211 and the IP ID together about 6 %, `csum_partial` 3 %, the copy from user space 3 %, nftables 3–4 %, then routing, the bridge, mac80211 and mt76. The radio and the driver reach a strong client fine, so the 8–10 Mbit/s of the phone above are not the limit of the 2.4 GHz radio.
* **mt7603 under width switches** (`hangload.sh`): 15 switches without load (3 at a real 40 MHz) and 12 while a UDP stream to the client kept 20–45 Mbit/s queued. Each took 7–9 s, without an MCU timeout or a task in D state. The hang of 2026-11-03 (TCP with many flows, the release kernel) did not come back.
* **The dynamic sensitivity of mt7603 with the own fix** (`dbglog.sh`): −100…−94 dBm at night on a quiet channel (false CCA per interval: OFDM 1–26, CCK 3–477), never above the weakest station's RSSI − 15 dB, and back to 0 (the default) in between. It moves, which it never did without the fix; its behaviour on a busy channel is still to be seen.

**The clock of the SPI flash** (2026-11-05, the debug image with `test_speed_hz`, `tests/router/spitest.sh`). The flash is a GigaDevice GD25Q64 (JEDEC `c84017`), at 10 MHz from `mt7628an_tplink_8m*.dtsi` (9.67 MHz: `spi-mt7621` divides the bus clock of 193.3 MHz by a whole number of at least 2). The test read everything but `rootfs_data` (7.9 MB) at the device tree's clock for reference and then at each clock, comparing SHA-256; the reference matched the flash dump of 2026-11-03 for every partition that has not changed since.

| Clock (divider) | Reads equal to the reference | Read rate (with `sha256sum` on the same CPU) |
|---|---|---|
| 9.67 MHz (20), the device tree's | — | 0.85 MB/s |
| 21.5 MHz (9) | 3 of 3 | 1.42 MB/s |
| 27.6 MHz (7) | 3 of 3 | 0.92–1.59 MB/s |
| 32.2 MHz (6) | 3 of 3 | 1.79 MB/s |
| 38.7 MHz (5) | 3 of 3 | 1.91 MB/s |
| 48.3 MHz (4) | 3 of 3 | 2.05 MB/s |
| 64.4 MHz (3) | 5 of 5 | 2.22 MB/s |
| 96.7 MHz (2) | 0 of 1: every partition but one differs | 2.43 MB/s |

* 96.7 MHz is above the 80 MHz the GD25Q64 allows for plain reads (opcode `03h`; the driver uses no fast read without `m25p,fast-read`), and the data came back corrupted. 64.4 MHz is the highest clock the controller offers below it.
* Writes at 64.4 MHz: three files of 32 KiB written to the overlay, read back at 9.67 MHz after dropping the caches: the same, without a JFFS2 error.
* The rate grows less than the clock: the driver moves 32 bytes per transaction and polls the controller with `udelay(1)` between them, all on the CPU. Without the checksums, the reads at 64.4 MHz take about a third of the time at 9.67 MHz.

**Decision (2026-11-05): the highest clock that works,** `spi-max-frequency` 65 MHz (64.4 MHz) in the device tree of the board. **Reopened (2026-11-06):** other units of the v4 carry Winbond or cFeon chips, which allow plain reads only up to 50 MHz ([section 15](#15-the-4pda-thread)); open in [TODO.md](TODO.md#open-decisions).

**Fast Read on the unit of the tests** (2026-11-06, a debug image with `m25p,fast-read` in the device tree; `spitest.sh -r` moves the Fast Read alone to the test clock, while the status, ID and write commands stay at 64.4 MHz, within the 80 MHz the GD25Q64 allows for them):

* The kernel reads with `0Bh` and 8 dummy cycles (`/sys/kernel/debug/spi-nor/spi0.0/params`). The flash's SFDP (SHA-256 `8aa60b77…`) also lists dual and quad reads, which `spi-mt7621` does not support.
* **96.7 MHz with Fast Read: the first round differed in every partition** but `romfile` (erased, all `0xff`), as with `03h` on 2026-11-05. The limit is not the access time of `03h` (the GD25Q64 allows `0Bh` up to 120 MHz) but when the controller samples the data: it works in SPI mode 0 only, where the flash drives a bit at the falling edge of the clock and the controller takes it at the rising one, half a period later. That is 5.17 ns at 96.7 MHz and 7.76 ns at 64.4 MHz, against the 7 ns (`tCLQV`, 30 pF) the GD25Q64 needs.
* Raw read rate of `rootfs` (`dd bs=64k`, 5.19 MB): 4.76 MB/s at 64.4 MHz with Fast Read against 4.7 MB/s with plain reads the day before, the same within the 10 ms resolution of `/proc/uptime`; 4.05 MB/s at 48.3 MHz with Fast Read (−15 %). Reads of 4 KiB (`head -c`) get 3.0 MB/s at 64.4 MHz: every `read()` of `/dev/mtdN` is one SPI message.
* Where the time goes at 64.4 MHz (`kprof` during the reads, share of the driver's samples): 71 % waiting for the transfer (`__udelay` in the poll of `mt7621_spi_wait_till_ready`), 19 % register reads, 10 % its own code. The bus clock sets the rate; the driver's overhead is about 2.8 µs per 32 bytes.

**For this unit 64.4 MHz is the highest clock** (96.7 MHz fails with either command, and the controller has no divider in between); Fast Read gains nothing at it.

**The other chips at 64.4 MHz.** If the controller samples at the rising edge, as the failure at 96.7 MHz suggests, every chip needs its `tCLQV` within 7.76 ns: Winbond W25Q64JV 6 ns, W25Q64FV 7 ns, XMC XM25QH64C 7 ns, GigaDevice 7 ns (works), cFeon EN25QH64A 8 ns at 30 pF and 6 ns at 15 pF. The load of one flash with short traces is well below 30 pF, so the cFeon is probably fine, but its datasheet does not promise it. At 48.3 MHz half a period is 10.35 ns, more than every chip needs, and plain reads stay within their 50 MHz.

**Decision (2026-11-06): every chip gets the chance of 64.4 MHz, by a check at boot, and falls back to 48.3 MHz.** The device tree sets 48.3 MHz (`spi-max-frequency` 50 MHz) and `openwrt,fast-frequencies = <65000000>`. Patch 951 of ramips (spi-nor) runs before the partitions are registered: the chip reads the first 128 KiB of the flash (the factory bootloader, read-only) at 48.3 MHz, then twice at 64.4 MHz, and keeps 64.4 MHz only if all three reads are equal; otherwise it stays at 48.3 MHz. `dmesg` logs the chip (JEDEC ID and the CRC-32 of its SFDP; the test unit: `c84017`, `8d73ddc9`) and its clock, so that reports from other units show which chips pass. The patch can also limit the check to listed chips (`openwrt,fast-flash`); a first version did that for the GD25Q64 alone, and the check for all was chosen instead. The risk taken: a chip that passes at boot may have less margin when the router is hot, most of all the cFeon EN25QH64A, whose datasheet leaves no margin at 64.4 MHz ([section 15](#15-the-4pda-thread)); no clock above 64.4 MHz can be tested for margin, since 96.7 MHz fails on the test unit too.

* Cost (release image, `o2`): kernel in flash 1934 → 1935 KiB, kernel in RAM 6483 → 6484 KiB (text +1 KiB), the image unchanged at 6401 KiB; at boot about 100 ms for the three reads (measured below).
* Not used: a userspace script at preinit (simpler, but the kernel's own first reads and the mount of the settings would run before it at the safe clock), and Fast Read (no gain at 64.4 MHz, and at 48.3 MHz the plain read is within every datasheet).
* **Checked on the router** (2026-11-06, the debug image `o2-dev-fc2`, whose device tree tries 96.7 MHz first, `<97000000 65000000>`, so that one boot runs both branches): `dmesg` at 3.317 s `c84017 (SFDP CRC-32 8d73ddc9): a read at up to 97000000 Hz differed from one at 50000000 Hz`, at 3.383 s `up to 65000000 Hz, 131072 bytes read the same as at 50000000 Hz`. Afterwards `rootfs` read raw at 4.76 MB/s (64.4 MHz; 4.03 MB/s at 48.3 MHz), and `spitest.sh` read every partition but `rootfs_data` the same at 48.3 MHz as at the clock the check chose, three times; `factory-uboot` equals the dump of 2026-11-03. From the controller's probe to the partitions took 138 ms against 9 ms before (one read at 48.3 MHz, one at 96.7 MHz, two at 64.4 MHz); the release image, without the try at 96.7 MHz, about 100 ms. The release image (`o2-fc2`) is still to be booted and its boot measured ([TODO.md](TODO.md#on-the-router)).

**The boot at 64.4 MHz** (the debug image, the first boot after a sysupgrade with the settings kept, one boot each; s after the kernel started):

| | 9.67 MHz | 64.4 MHz |
|---|---|---|
| preinit | 10.7 | 7.9 |
| procd init | 32.3 | 24.8 |
| modules loaded | 40.8 | 30.5 |
| LAN bridge forwarding | 78.5 | 58.3 |
| WAN up / wg0 up | 154 / 164 | 85 / 85 |
| 2.4 GHz / 5 GHz access point | 239 / 336 | 139 / 194 |

Every step comes earlier, the WAN by 69 s. The debug image boots slower than the release image (less free RAM, more reads); the release image is still to be measured with the same reboots as in the boot investigation above.

**A day on the debug image at 64.4 MHz** (2026-11-05, 01:21–17:53 UTC, nobody testing; `dbglog.sh` every 5 minutes, `abwatch.sh`):

* **Stable:** no hung task, soft lockup, workqueue stall, MCU timeout, flash or JFFS2 error in 16.5 hours; `MemAvailable` 14.1–14.9 MB throughout.
* **Hardly any load:** the CPU was 96–97 % idle in every hour. The profile watcher found only one 10 s stretch above 50 %: the first DHCP renewal after the boot (the lease time changed), which reloads the firewall and restarts the DoH proxies; their programs came back from the flash (LZMA 9 %, the SPI driver's `udelay` 2 % of the samples). Later renewals with the same lease change nothing. So the A/B of GRO got no data and needs load.
* **The dynamic sensitivity of mt7603 on a busy channel** (false CCA up to 2426 per interval, 346 on average, 199 snapshots): the threshold moved between −100 and −82 dBm and was back at 0 in 17 % of the snapshots. It stayed near the weakest client's RSSI − 15 dB: at most 3 dB above it by the last frame's signal, while the driver uses the average.
* **Clients:** none on 5 GHz all day. On 2.4 GHz, in power save in 82–92 % of the snapshots, with few filtered frames:

| Client | Frames sent | Retries per frame | Failed |
|---|---|---|---|
| The phone (−70…−20 dBm, 2 streams) | 452 514 | 0.50 (0.78 from 09:00 to 12:30, at 1 stream when it moved) | 1.01 % |
| A power-save device (−58…−32 dBm) | 20 755 | 0.76 | 0.46 % |
| An IoT device (−47…−43 dBm, 4 reconnects) | 67 642 | 0.16 | 0.54 % |

The power-save device failed 5.2 % of its frames on the release image on 2026-11-03 (its counters since the boot, in other conditions); here 0.46 %.

**GRO and flow offloading with iperf3** (2026-11-05, 20:43–21:31 local time, the debug image at 64.4 MHz). An iperf3 server on a remote host (a public address, 400+ Mbit/s up), clients at the site behind the router's NAT: a Windows PC on the cable (`tests/router/iperf-pc.ps1`) and an Android phone on 5 GHz (`iperf-phone.sh`), each run 4 TCP streams for 20 s in a 240 s cycle kept by the clock; `labtest.sh` set one state per cycle and profiled each run with `kprof` (12 cycles, each state 3 times). The PC's Wi-Fi was not connected, so its runs are missing. CPU busy per Mbit/s, mean of the three runs:

| Run | A: GRO with fraglist (default) | B: GRO without fraglist | C: no GRO | D: A without flow offloading |
|---|---|---|---|---|
| PC cable, download (WAN → LAN) | 75 Mbit/s, 0.74 %/Mbit | 72–84 Mbit/s, 0.72 | 64–78 Mbit/s, 0.67 | 68–70 Mbit/s, 1.34 |
| PC cable, upload (LAN → WAN, the port's 100 Mbit/s) | 0.59 (busy 42–86 %) | 0.73 | 0.49 | 1.02 (busy 100 %) |
| Phone, upload (Wi-Fi → WAN) | 85–93 Mbit/s at 99–100 % busy, 1.11 | 79–87 Mbit/s, 1.18 | 84–90 Mbit/s at 91–96 %, 1.06 | 69–73 Mbit/s at 100 %, 1.41 |
| Phone, download (WAN → Wi-Fi) | 12–20 Mbit/s at 24–36 % busy in every state | | | |

* **Flow offloading is worth its place:** without it the same traffic costs 1.3–1.8 times the CPU, and the phone's upload fell from about 90 to 70 Mbit/s.
* **GRO without fraglist is the worst state with GRO**, as expected: the merged packets are split again with copies, and `csum_partial` grew from 8.8 % of the samples (A) to 13.8 % in the phone's upload.
* **No GRO is the cheapest:** 5–17 % less CPU per Mbit/s than the default, and `csum_partial` left the top of the profile (Wi-Fi and `eth0` compute no checksums in hardware, so a merged packet is checksummed again when it is split). The phone's upload kept its rate with 4–9 % of the CPU left over. The gain is modest: the rest of the cost is the drivers (`fe_poll`, `fe_reg_r32` 7 % of the cable download, `mt76_dma_rx_poll`), softirq handling, the flow table and hashing.
* **The phone's download was limited before the router:** about 2 % of the TCP segments were retransmitted from the first second, with a congestion window of 11–113 KB, against 0.2–0.4 % for the PC on the cable over the same path. The router dropped nothing (interface drops, mac80211 queue drops, conntrack drops all 0), its queues to the phone were empty, and the phone (−46 dBm, VHT MCS 9, 2 streams) needed 0.01 retries per frame. Likely the ISP's 100 Mbit/s policer at the site and the bursts that Wi-Fi's aggregated TCP ACKs make the 1 Gbit/s sender send. A server in the site's LAN is needed to measure the router's own download over Wi-Fi.

**The ISP's policer, with a paced server** (the same evening). For three cycles the server paced every TCP flow at 24 Mbit/s (`tc qdisc replace dev … root fq maxrate 24mbit`): the PC on the cable then downloaded 92.0, 92.4 and 92.8 Mbit/s with 0–5 retransmissions per run, against 50–81 Mbit/s with 187–495 retransmissions in the 25 runs without pacing. The losses are the ISP's 100 Mbit/s policer dropping the bursts of a 1 Gbit/s sender; Wi-Fi's aggregated ACKs make the bursts larger, hence the phone's worse download through the internet. Not the router.

**Wi-Fi ↔ LAN with an iperf3 server on the PC at the site** (21:48–23:51 local time; the phone on 5 GHz at about −46 dBm, VHT MCS 9, 2 streams; the internet runs of the PC paced as above until 23:23). A first try was discarded: a download of about 90 Mbit/s from the LAN to Wi-Fi kept the CPU so busy that the lab script did not wake up for up to 24 s, and its windows slid onto the next run. `kprof` now starts 2 s before each run and counts the traffic itself (`labtest.sh`, `kprof.c`). States A (the default), C (no GRO), T (the default with threaded NAPI on `eth0`), U (no GRO and threaded NAPI); three runs each, A/C/T and T/U in two series. The CPU per Mbit/s, and how late a timer of 100 ms in a process at normal priority ran:

| Run | A | C | T | U |
|---|---|---|---|---|
| Phone ← PC (LAN → 5 GHz) | 88–91 Mbit/s, 1.04 %/Mbit, late 0.96–1.26 s | 93 Mbit/s, 1.02, late 8.8–9.9 s | 91–93 Mbit/s, 1.01, late 0–1 ms | 91–95 Mbit/s, 1.01, late 0–1 ms |
| Phone → PC (5 GHz → LAN) | 77–81 Mbit/s, 1.19 | 82–85 Mbit/s, 1.11 | 76–83 Mbit/s, 1.17 | 87–90 Mbit/s, 1.05 |
| PC cable download (paced, CPU not saturated) | 0.70 | 0.61 | 0.75 (0.78 unpaced) | 0.67 (unpaced) |
| PC cable upload (the port's limit) | 0.60 | 0.50 | 0.53–0.64 | 0.56 |

* **The router itself reaches about 90 Mbit/s to a phone on 5 GHz** (the PC's port is 100 Mbit/s), with the CPU 91–96 % busy; from the phone about 80–90 Mbit/s.
* **Without threaded NAPI such a download starves every process of the router:** the receive path of `eth0` runs in softirq context and takes the CPU from hostapd, dnsmasq, netifd and dropbear for a second (A) or ten (C, more packets without GRO). With NAPI in a kernel thread (`/sys/class/net/eth0/threaded`, netifd's device option `threaded`) the scheduler shares the CPU: 0–1 ms, at the same rate and cost. netifd has no option for it (2026-11-06, its sources), so a default needs a hotplug script that writes the file.
* **No GRO with threaded NAPI (U) is the best state:** the phone's upload 10 % faster at 10 % less CPU per Mbit/s, the cable download 14 % cheaper, `csum_partial` gone from the profile, nobody starved.
* **Where mt76 spends the time** (`modsym.py`, the unstripped modules of the build tree, whose `.text` equals the router's): in the phone's download `mt76_dma_tx_cleanup` takes 28–34 % of the module samples (about 15 % of the CPU) and `mt76_mmio_rr` 10–11 % in every state. Both wait for reads of MT7612E registers over PCIe: the DMA index of each TX queue and two words of the TX status FIFO per frame (`mt76x02_mac_load_tx_status`). No interrupt is coalesced: `MT_WPDMA_DELAY_INT_CFG` is set for TX (0x94ff0000: 20 frames or 5.1 ms), but the driver never puts `MT_INT_TXDELAYINT` into its interrupt mask, so every TX completion and every received batch raises its own interrupt (corrected on 2026-11-06 after openwrt/mt76 PR #1138, which disables the unused setting). UDP sent by the router itself reached 20 Mbit/s on 5 GHz at 88–93 % CPU against 45 Mbit/s on 2.4 GHz, where the MT7628's radio sits on the SoC's bus.

**The two checks before GRO goes off, and the phone on 2.4 GHz** (2026-11-06, 02:00–07:20 local time, the debug image with the flash at 64.4 MHz; `tests/router/wifitest.sh`, `grocheck.sh`; nobody at the site, the phone on the charger running `iperf-phone.sh` against the remote server, on 2.4 GHz at −63…−68 dBm, HT MCS 15, 2 streams). States A and U as above.

* **WireGuard is faster in U, both ways.** iperf3 on the router through its tunnel to a host behind a VPS (round trip about 85 ms), one TCP stream for 20 s per run, the remote side paced at 40 Mbit/s per flow (unpaced, the ISP's policer cut the download to 12.6 Mbit/s with the CPU 45 % idle). This is the router's own traffic, iperf3 included; forwarding into the tunnel for the LAN costs no iperf3 but the same crypto.

| Run | A | U |
|---|---|---|
| Upload (the router encrypts) | 25.9–28.8 Mbit/s, mean 27.7 (5 runs), CPU idle 19–30 % | 29.7–29.9 Mbit/s, mean 29.8 (5 runs), idle 32–37 % |
| Download (the router decrypts) | 22.8–23.3 Mbit/s, mean 23.1 (4 runs), idle 13–18 % | 24.5–24.9 Mbit/s, mean 24.7 (5 runs), idle 10–12 % |

  U is 8 % faster in the upload with more CPU left, 7 % in the download. One more run in A (19.3 Mbit/s at 97 % idle) is left out: the path, not the router. In the upload `chacha_crypt_arch` takes 17 % of the samples and `poly1305_blocks_mips` 4 %; the CPU is not saturated there (one stream over 85 ms), in the download it nearly is.
* **netifd's `gro` option reaches every interface, Wi-Fi included.** A device section with `option gro '0'` for `eth0`, `phy0-ap0` and `phy1-ap0`, then a restart of the network (what a boot does): GRO off on all three, and still off after `wifi up radio0` rebuilt the 2.4 GHz interface; `ubus call network.device status` reports `"gro": false`. GRO off therefore needs only configuration, no `ethtool` in the image. Removing the option does not turn GRO on again on `eth0` until a reboot (netifd sets it only when configured); the Wi-Fi interfaces, created anew, came back with GRO on. `eth0.1`, `eth0.2` and `br-lan` keep their flag on, which does not matter: GRO runs in the NAPI of `eth0`.
* **UDP from the router to the phone on 2.4 GHz:** 25.6 Mbit/s (A) and 37.1 Mbit/s (U) with 0.01–0.04 retries per frame and no failed frame; the CPU was 4 % idle, so the router's own sender was the limit, not the radio. With TCP the phone downloaded 26–45 Mbit/s and uploaded 54–86 Mbit/s through the internet over 2.4 GHz (the server paced for the downloads). The slow 2.4 GHz of 2026-11-03 (8–10 Mbit/s next to the router) did not show.
* **The phone's iperf3 hung four times** after a download through the router (04:02, 04:38, 06:06 and 06:18 local time): the server got no results ("unable to receive results"), and the client stayed blocked until the phone lost Wi-Fi for longer than a few seconds (a restart of the network, a move to the other band, both radios down for 45 s; a TCP reset of its control connection did not free it). In 06:06 and 06:18 the server counted 0 bytes sent and 16–22 retransmissions while the router passed 4 Mbit/s to the phone with 0.05 retries per frame and no failed frame. `kprof` was sampling in three of them, not in the fourth, and no WireGuard test ran before the third, so neither is the cause. The same stalls (0 bytes and retransmissions, "idle timeout") showed when the phone used its mobile network after 07:22, so they are not the router's; the phone, asleep on the charger, is the likely side.
* **Forced moves between the bands (WPA3):** the phone uses another random MAC on each network; 2.4 GHz has WPA2-PSK, 5 GHz WPA3-SAE only, where the phone had −82 dBm. Deauthenticated from 2.4 GHz with a ban of 60 s (`ubus call hostapd.phy0-ap0 del_client`), it joined 5 GHz 4 s later, with SAE, the 4-way handshake and DHCP within 1–2 s. Deauthenticated from 5 GHz the same way, it tried no network for 3.5 minutes and came back to 2.4 GHz: Android takes the rejections during a ban for a failing access point and stops trying it for minutes. With the 2.4 GHz radio down for 100 s instead (`tests/router/bandswitch.sh`), it did not join 5 GHz and came back to 2.4 GHz 3.5 minutes after it lost it, 1 min 50 s after the radio was up, while the other clients rejoined in 2–4 s. With the screen off Android scans about every 3.5 minutes, so moves forced on a sleeping phone measure Android, not the router. Every attempt that came completed within a second, SAE at −82 dBm included, without the "did not acknowledge authentication response" of 2026-11-05.
* **The width switch under TCP** (`tests/router/hangtcp.sh`, the mt7603 hang of 2026-11-03): one switch to HT40 during the phone's download at 42 Mbit/s (the coexistence scan kept 20 MHz) was up again after 9 s without an MCU timeout. The phone's iperf3 then hung (above), so no more switches had load; the test needs a client that keeps its TCP running through a reconnect, e.g. a PC with a torrent.
* **The phone's own traffic in A and U** (`wifitest.sh` with `KPROF=none`, 07:00–07:20 local time, the phone at −64…−70 dBm, the server paced at 24 Mbit/s per flow, 4 flows): the CPU per Mbit/s of what the router forwarded to and from the phone, from `/proc/stat`.

| Cycle | Download | Upload |
|---|---|---|
| U | (no run) | 50.5 Mbit/s, CPU idle 59 %: 0.81 % per Mbit/s |
| A | 21.5 Mbit/s, idle 54 %: 2.1 % per Mbit/s | 44.2 Mbit/s, idle 45 %: 1.2 % |
| U | 38.2 Mbit/s, idle 53 %: 1.2 % | 55.0 Mbit/s, idle 47 %: 0.96 % |
| A | 30.8 Mbit/s, idle 57 %: 1.4 % | 52.8 Mbit/s, idle 50 %: 0.95 % |

  Two cycles of each state point the same way as WireGuard (U no dearer, the download cheaper), but the internet path set the rates, so they do not decide. In U the receive work of `eth0` moves from softirq (19–24 % in A) to its NAPI thread, counted as system time (40 %, softirq 5 %). A bug of the script (fixed) took both radios down after every cycle, at the end of the phone's upload, so every upload lost its results on the server and the phone needed a minute to come back.
* **The series ended at 07:18–07:20 local time** (05:18–05:20 UTC), in its sixth cycle: an outage of the ISP in part of the city cut the site off (the owner), and the phone moved to its mobile network at 07:22. Not a fault of the router.
* **The A/U series again, by day** (09:30–10:20 local time, 12 cycles, the fixed script; the owner says the phone may have been moved and in use): every run of the phone completed, 24 runs without a hang and without a restart of the radios. The 2.4 GHz link was the limit:
  * downloads were 2.8–12.9 Mbit/s at the server and uploads 19–37, with the CPU 56–92 % idle;
  * the router's frames to the phone were retried 0.5–1.9 times each, and 184–1873 of them failed per 22 s. At night, at the same −57…−71 dBm, it was 0.07–0.38 retries and 5–409 failed frames;
  * channel 1 was busy 19 % of the time since the boot, 14 % of it by other networks.

  At these rates A and U do not differ: uploads took 1.30 % (A) and 1.25 % (U) of the CPU per Mbit/s, means of 6 runs each that scatter over 0.9–1.9; the downloads were too slow to tell. The slow 2.4 GHz of 2026-11-03 showed again by day, with the phone perhaps in use, and not at night with the phone asleep and in power save. That points at the phone or the air (Bluetooth sharing the phone's 2.4 GHz radio, other networks) more than at the power save of `mt7603`. The owner adds that the phone streams audio to Bluetooth headphones almost all the time. Bluetooth and 2.4 GHz Wi-Fi share the phone's radio and antenna, and while Bluetooth has them the phone cannot receive: the router's frames to it are retried and lost, while the phone's own uploads, which it times around Bluetooth, go through. That fits the slow downloads with fast uploads, and 5 GHz, which Bluetooth does not use, was fast on 2026-11-03. At night the phone lay asleep on the charger.

**Decision (2026-11-06): GRO off and threaded NAPI on `eth0` by default** (the owner, after the two checks above and an account of what GRO off costs: nothing measured, against the defaults of OpenWrt, IPTV, PPPoE on the router and a long run not yet measured in U). GRO is off in the kernel: `register_netdevice()` turns on GSO for a new network device but not GRO (`target/linux/generic/hack-6.12/601-…`), so every interface starts without it, without any configuration: `eth0`, every Wi-Fi interface (the access points, a guest network, the client of travelmate) and the tunnels of WireGuard and AmneziaWG, whose decrypted packets go through GRO on `wg0`. GRO stays a changeable feature: a device section with `option gro '1'` turns it on for that device, with fraglist, as OpenWrt has it. `/etc/init.d/a5v4-threaded-napi` writes 1 to `/sys/class/net/eth0/threaded` at every boot (`a5v4.network.threaded_napi '0'` turns it off).

* **Threaded NAPI: an init script, not a hotplug script.** The first version wrote the file from `/etc/hotplug.d/net` when `eth0` appeared. It passed the QEMU bench and did nothing on the router (2026-11-06, the first flash of this image): the built-in Ethernet driver creates `eth0` at 3 s, before procd starts, and procd's coldplug (`udevtrigger`) announces only devices with a device node, so no `add` event of `eth0` came. On malta `eth0` is the module `pcnet32`, loaded by the boot script, and its event came. The init script runs at `START=11`, after the boot script has loaded the modules, on both.

* **First as configuration, then in the kernel.** The first version added device sections with `gro '0'` for `eth0`, `phy0-ap0` and `phy1-ap0` to the first-boot defaults; netifd's `gro` option reaches the Wi-Fi interfaces. It left out every interface with another name: the client of travelmate, access points added later, the tunnels. The owner asked for GRO off everywhere, so the patch replaced the sections on the same day. A hotplug script could not do it without `ethtool` (about 100 KiB), and it would leave each interface with GRO for a moment.
* **On the router** (the release image with patch 601 and without IPTV, flashed with the settings kept, 2026-11-06 evening): GRO off on `eth0`, `eth0.1`, `eth0.2`, `br-lan`, both access points and `wg0` with no `gro` option in the configuration; the flash at 64.4 MHz; no multicast routing; Wi-Fi, the tunnel and the clients back about 3 minutes after the start of `sysupgrade`. Threaded NAPI was off (the hotplug script, above) and was set by hand for the measurement.
* **GRO on `wg0` changes nothing** (the same evening, the same iperf3 through the tunnel as above, `ethtool` from `/tmp` switching GRO of `wg0` off and on in turn, 4 runs each way and state): upload 31.2 Mbit/s with GRO off (28.1–32.7, CPU idle 40 %) and 31.6 with it on (31.3–31.9, 38 %); download, where the router receives the TCP through `wg0`, 27.0 (26.9–27.1, idle 15 %) and 27.05 (26.8–27.3, 15 %). Against the night's state U on the debug image (29.8 and 24.7) the release image is 6–9 % faster. The client of travelmate is not measured; it takes the same receive path as the access points.

* **Not `board.json`.** netifd takes a default for a device from `/etc/board.json` (`network_device.<name>.gro`, applied when it claims the device), which would have kept the setting out of the user's configuration. On the QEMU bench it worked for `eth0` and not for the Wi-Fi interfaces: jshn turns a `-` in a key into `_` when it loads JSON (`phy0-ap0` → `phy0_ap0`), and every `board.d` script loads and writes the file again, `99-default_network` of base-files last. OpenWrt's helper `ucidef_set_network_device_gro` also writes the value as a string, `"gro": "0"`, which netifd ignores: with GRO on, the string left it on and a boolean `false` turned it off (bench hook). No board of the tree calls the helper ([TODO.md](TODO.md#to-submit-upstream)).
* **QEMU bench** (`o2`): 60 checks, none failed or skipped: no `gro` option in the configuration, GRO off on `eth0`, on the access point and the client of `mac80211_hwsim` (also after `wifi down; wifi up`) and on `wg0`, threaded NAPI with its `napi/eth0-*` thread, both again after a reboot, and a device section with `gro '1'` turns GRO on for the WAN card. In one run of the version with sections the router did not answer SSH within 300 s after the reboot at the end of the bench; its console was overwritten by the next run, and the four later reboots with threaded NAPI came up in 25–80 s.
* **Cost:** none measurable; the kernel has the same size. With IPTV left out the same day ([section 8](#8-routing-acceleration-and-iptv)) the image is 6337 KiB (1279 KiB free for settings), `root.squashfs` 4390 KiB, the kernel 1919 KiB in flash and 6429 KiB in RAM.

**Group 1 of the search for speed, and interrupt moderation** (2026-11-06 evening, the debug image `o2-dev-irq`: mt76 `0323`–`0326` and `ethtool -C` of the Ethernet driver, flashed with the settings kept; nobody at the site; [section 8](#8-routing-acceleration-and-iptv) has the search):

* Threaded NAPI came up at boot from the init script (`threaded` 1, `napi/eth0-2`); GRO off everywhere; the flash at 64.4 MHz.
* **RSSI from RCPI** (`0325`): the two 2.4 GHz clients read −56…−54 and −59…−57 dBm over a minute in 2 s steps; the first of them read −53 dBm with IBRssi an hour before. The deadlock fix (`0323`) and the EDCA change (`0324`) have nothing to show without a failed channel switch or a client that changes the slot time.
* **Interrupt moderation of `eth0` changes nothing at the packet rate of WireGuard.** iperf3 of the router through its tunnel (the server paced at 40 Mbit/s), each variant 3 times in turn; downloads, where the CPU is nearly busy:

| Variant | Mbit/s | CPU idle | Interrupts of `eth0` per second |
|---|---|---|---|
| none | 25.8 | 19 % | 1490 |
| `napi_defer_hard_irqs` 2, `gro_flush_timeout` 50 µs | 25.4 | 16 % | 310 |
| delay interrupt, 100 µs or 8 frames | 25.9 | 20 % | 1500 |
| delay interrupt, 200 µs or 32 frames | 25.7 | 22 % | 1240 |

  Uploads were 22.5–30.9 Mbit/s in every variant. At about 2300 packets/s the gap between two packets exceeds the delay, so the hardware coalesces little, and the interrupts cost under 1 % of the CPU: the tunnel is bound by its crypto. The cost shows in the ping to the ISP's gateway at idle: 3.20 ms on average (minimum 3.03) without moderation, 3.22 with the kernel's deferral, 3.25 (3.12) at 100 µs and 3.31 (3.23) at 200 µs, the delay as configured. Switching at run time never disturbed `eth0`.
* **The delay interrupts of the MT7612E** (`delay_int` 0x9032880a: TX after 16 frames or 1 ms, RX after 8 frames or 200 µs) brought the 5 GHz access point up after `wifi up radio1` with 22 interrupts/s at idle (21 without) and no error. No client was on 5 GHz, so their effect on throughput is not measured.

**Decision (2026-11-06):** `0323`–`0325` stay in the build; the switches stay off by default until a load of 90–100 Mbit/s (a PC on the cable, LAN ↔ 5 GHz) shows whether they pay ([TODO.md](TODO.md#on-the-router)).

**The same with clients at the site** (2026-11-06 23:36 – 2026-11-07 00:55 local time, the debug image `o2-dev-irq`): a PC on the cable downloading from and uploading to an iperf3 server on the internet (paced at 24 Mbit/s per flow, 4 flows), a phone next to the router on 5 GHz (−42…−47 dBm, VHT MCS 9) against an iperf3 server on that PC, `iperf-pc.ps1` and `iperf-phone.sh` in their 240 s cycle, on the router one state per cycle with `kprof` over each run. States: N, no moderation; E, the delay interrupt of `eth0` at 200 µs or 16 frames (RX) and 200 µs or 32 frames (TX); W, E and `delay_int` 0x9032880a of the MT7612E. Two series, N N N E E E W W W N N N and E W W W E E.

| PC on the cable | N (6 runs) | E and W (12 runs) |
|---|---|---|
| Download, 83–89 Mbit/s | 0.67 % CPU per Mbit/s, idle 41 %, 19 000 interrupts of `eth0` per second | 0.54, idle 53 %, 6 100 |
| Upload, 87–92 Mbit/s | 0.58, idle 48 %, 8 400 | 0.46, idle 58 %, 4 900 |

* **The delay interrupt of `eth0` saves about a fifth of the CPU per Mbit/s on the cable** at the same throughput (the port is the limit), with a third of the interrupts; a timer of a process ran late by 0–1 ms in every run. Its cost is the latency of the delay (0.2 ms at idle, above). E and W are the same here, as they should be.
* **The phone (5 GHz ↔ the PC on the cable), only in E** (4 runs each way): downloads 91–93 Mbit/s (the PC's port), uploads 56–92, at 5–10 % idle and 1.00–1.03 % per Mbit/s, as in state U on 2026-11-05 (1.01 and 1.05); 2 300 interrupts/s of `eth0` and 2 300–5 100 of the MT7612E. In one upload a process waited 273 ms for the CPU, in all others 0–3 ms.
* **The delay interrupts of the MT7612E are still not measured.** Twice the phone did not come back to 5 GHz after `wifi up radio1` applied `delay_int`: the first time it moved to 2.4 GHz (and there, at −25 dBm, downloaded 42–51 Mbit/s and uploaded 54–67 with half the CPU idle: no slow 2.4 GHz that night), the second time, with 2.4 GHz down, it did not rejoin at all for 20 minutes. The test needs `delay_int` applied without a restart of the radio.
* **The delay interrupts of the MT7612E change nothing measurable** (2026-11-07, 01:11–01:35 local time; the phone on 5 GHz at −37…−45 dBm with the 2.4 GHz network forgotten, reconnected by hand once after a restart; `eth0` at 200 µs in every cycle; E E W W E E, UDP from the router to the phone with `udptest.sh` in the PC's slot):

| Run | `delay_int` 0 (E) | `delay_int` 0x9032880a (W) |
|---|---|---|
| UDP from the router, CPU-bound | 19.7 Mbit/s, 4.96 % per Mbit/s, 3 200 interrupts of the MT7612E per second (3 runs) | 19.8, 4.87, 2 200 (2 runs) |
| Phone ← PC (LAN → 5 GHz) | 91.7 Mbit/s, 1.01 %, 4 800 (4 runs) | 91.9, 1.01, 2 800 (2 runs) |
| Phone → PC (5 GHz → LAN) | 87.4 Mbit/s, 1.05 %, 2 600 | 85.8, 1.08, 1 600 |

  A third to two fifths fewer interrupts, the same throughput and CPU: the interrupts of the MT7612E are not where its CPU goes (the TX cleanup with its reads over PCIe runs as often from NAPI).

**Decision (2026-11-07): both delay interrupts on by default** (the owner). `eth0` at 200 µs or 16 frames received and 200 µs or 32 sent (`FE_DLY_INT_DEFAULT` of the Ethernet driver, `0xa00a900a`; `ethtool -C` changes it in the debug image): a fifth less CPU per Mbit/s on the cable for 0.2 ms of latency. The MT7612E at `delay_int` 0x9032880a (TX after 16 frames or 1 ms, RX after 8 frames or 200 µs; `mt76x02-lib delay_int=0` in `/etc/modules.d` turns it off): no gain measured, no harm measured; the owner keeps it to watch it in use, where a mix of loads (many 5 GHz clients with small packets, 5 GHz with a tunnel or the cable at once) could gain a little from fewer interrupts. Its costs to watch: up to 0.2 ms more latency on 5 GHz when traffic is sparse, TX completions up to 1 ms later (the airtime accounting of AQL sees the frames in flight that much longer; the TX status of rate control has its own interrupt), and a mode of mt76 that nobody else runs.

**The same for the 2.4 GHz radio (2026-11-07, the owner):** the bottleneck there was the air at this site, not at every one, so the mt7603 gets the delay interrupts too (`0327`, `delay_int` of `mt7603e`, 0x9032880a). The 2.4 GHz runs of the phone that night took 1 800–3 000 interrupts of the mt7603 per second with half the CPU idle, about the rate of the MT7612E with its delay, so no measurable gain is expected here either. The status bits of its delay interrupts are in no header, vendor or mt76: with `MT_DELAY_INT_CFG` set for one direction at a time through the register files of mt76's debugfs while a client was pinged, `MT_INT_SOURCE_CSR` showed bit 22 for RX and bit 23 for TX (twice each), next to the coherent bits 20 and 21; the configuration went back to 0 after the probe.

**The release image with these defaults on the router** (2026-11-07, 02:05 local time, `o2-rel-irq2`, flashed with the settings kept, back after about 3 minutes): `delay_int` 0x9032880a for both radios, threaded NAPI with `napi/eth0-2`, GRO off on `eth0` and both access points, the flash at 64.4 MHz, no unknown symbol or MCU timeout. The delay interrupt of `eth0` shows in the ping to the ISP's gateway at idle: 3.22 ms minimum (3.03 without it). The first run of the mt7603 with its delay interrupts on a real radio: 500 pings of 1400 bytes to a client on 2.4 GHz at −53 dBm without a loss, 1.8 ms minimum and 2.4 ms on average, 1 572 interrupts of the mt7603 for them. `MemAvailable` 19.4 MB two minutes after the boot.

## 13. VPN: WireGuard and AmneziaWG

**Modules, loaded with a tunnel.** Built in, WireGuard took kernel RAM on every router, also on those without a tunnel. AmneziaWG is built outside the kernel tree and can only be a module. Both are modules now and take RAM only while a tunnel exists:

* **WireGuard:** `kmod-wireguard` loses its `AUTOLOAD` (`package/kernel/linux/modules/netsupport.mk`). netifd creates the interface with `ip link add … type wireguard`, the kernel asks for `rtnl-link-wireguard`, and OpenWrt's `modprobe` loads the module. The ChaCha20 and Poly1305 of MIPS come with `kmod-crypto-lib-chacha20` and `-poly1305` (`chacha-mips.ko`, `poly1305-mips.ko`) instead of being built in.
* **AmneziaWG:** its protocol handler (`amneziawg.sh`) runs `modprobe amneziawg` itself.
* **The UDP tunnel code** both use (`NET_UDP_TUNNEL`, `kmod-udptunnel4/6`) stays built in.

**AmneziaWG** comes from the feed [awg-openwrt](https://github.com/Slava-Shchipunov/awg-openwrt), pinned in `feeds.conf.default` to `03b62269e2` (AmneziaWG 3.1):

* the packages are `kmod-amneziawg` 3.1.20260906, `amneziawg-tools` 3.1.20260812 (`awg`, the netifd protocol `amneziawg`) and `luci-proto-amneziawg` with a Russian translation;
* without the obfuscation options (`awg_jc` … `awg_i5`) AmneziaWG speaks plain WireGuard;
* WireGuard stays too: it is upstream's, with its own LuCI page and `wg`. AmneziaWG is for those whose ISP blocks WireGuard by DPI.

**Kernel symbols.** AmneziaWG and mac80211 with IPv6 needed 67 symbols that `TRIM_UNUSED_KSYMS` had dropped (`in4_pton`, `in6_pton`, `ip6_dst_lookup_flow`, `strsep`, `kstrtoint` … for AmneziaWG; `register_inet6addr_notifier` and its unregister counterpart for mac80211), and modpost stopped the build on them. A module built outside the tree that misses a symbol stopped the build before `kernel-symbols.txt` was written, so the whitelist could not be regenerated the usual way. `build.sh` therefore makes modpost only warn (`KBUILD_MODPOST_WARN=1`); its own check then lists what is missing. The whitelist is the union of both builds again: 506 symbols, 445 for the router and 489 for QEMU.

**Cost** (packages as `.apk`, KiB):

| What | Packages | Size |
|---|---|---|
| AmneziaWG | `amneziawg-tools` 43, `kmod-amneziawg` 44, `luci-proto-amneziawg` 29, Russian 4 | 120 |
| WireGuard as a module | `kmod-wireguard` 37, the crypto libraries 17, in `root.squashfs` instead of the kernel | 54 |

**Measured (2026-11-03, QEMU bench):**

* both modules are not loaded after the boot and are loaded with the tunnel;
* AmneziaWG without obfuscation completes a handshake with a WireGuard peer, and SSH works through it;
* two AmneziaWG interfaces with obfuscation (`jc 4`, `jmin 8`, `jmax 80`, `s1 15`, `s2 30`, `h1`–`h4`) complete a handshake *(bench)*.

Throughput on the router is still to be measured ([TODO.md](TODO.md#checks-and-measurements)).

**Decision (2026-11-03):** both, as modules loaded with a tunnel.

## 14. Encrypted DNS (DoH)

**Setup.** `https-dns-proxy` 2026.05.06 with `luci-app-https-dns-proxy` (Russian), configured as in openwrt-ax3200 (first-boot defaults, marker `a5v4.defaults.doh`):

* two instances, Cloudflare (`127.0.0.1#5053`) and Google (`#5054`), as the package ships them;
* `dnsmasq_config_update '*'`: dnsmasq asks only them (the service sets `noresolv`);
* `force_dns '0'`: clients are not forced onto the router's DNS. `force_dns` would also reject DNS over TLS (port 853), which breaks the Private DNS of Android;
* `conn_loss_time '30'`;
* libcurl with HTTP/2 (`libnghttp2`), since the router test ([section 12](#12-tests-on-the-router)): https-dns-proxy asks for HTTP/2 by default and sends the requests of an instance over one TLS connection, as parallel streams. Without it every request logged an error, and parallel requests needed a TLS connection each.


**Cost:**

* flash: `https-dns-proxy` 34, `libcares` 101, `libev` 26, the LuCI app 12, Russian 4: 177 KiB as `.apk`. libcurl and `ca-bundle` were already there for travelmate;
* RAM: 144 kB private and about 2.3 MB resident per instance, two instances *(bench)*;
* HTTP/2 of libcurl: `root.squashfs` 4370 → 4431 KiB, the image 6337 → 6401 KiB (1215 KiB free); `libnghttp2` is 72 KiB as `.apk`, and libcurl grows by 16 KiB. An instance then takes 160 kB private and about 2.5 MB resident *(bench)*.

**When DoH does not answer** (the DoH servers blocked or unreachable), no name resolves: dnsmasq asks only the proxies, and https-dns-proxy answers nothing when its request fails (`doh_response_cb()`). NTP cannot resolve its servers either. On the bench, which has no internet, the DNS and NTP checks failed this way. A fallback to the ISP's servers was built and measured: an option of the init script that keeps the resolv file and sets dnsmasq's `strict-order` instead of `noresolv`. In strict order a client retry moves the query one server down the list (`forward.c`), and dnsmasq's own `fast-dns-retry` resends to the same server. So with two instances the ISP's server answers only the third try. Linux (glibc), Android, the router's musl and busybox `nslookup` make two: with DoH down they still got no answer. With one instance the ISP answers the first retry. **Decision (2026-11-03): as in openwrt-ax3200, two instances and no fallback.** The fallback is not in the build.

**Found: proxy addresses left in dnsmasq** (feed patch `feeds-patches/packages/0001-*`, also in upstream master):

* the service backs up the server list of dnsmasq once, as a single empty entry when dnsmasq has none (the default);
* the service starts more than once after a boot, and every later start took that entry for a missing backup and backed up the proxy addresses into it (`doh_backup_server '' '127.0.0.1#5053' '127.0.0.1#5054'` on the bench);
* stopping or disabling DoH then put the proxy addresses back into dnsmasq, and an instance deleted in LuCI kept its address there.

The fix tests that the backup exists, as the restore does. A new test of the package covers it: it fails without the fix, and all 132 tests pass with it.

**Turning DoH off** (for the README): LuCI → Services → HTTPS DNS Proxy, “Stop” and “Disable”, or `/etc/init.d/https-dns-proxy stop; /etc/init.d/https-dns-proxy disable`. dnsmasq then asks the ISP's DNS again, with no proxy address left. The bench checks this before its DNS and NTP checks *(bench)*.

**On the router** (2026-11-03, [section 12](#12-tests-on-the-router)): DoH answers, and the router sends no DNS in the clear. With HTTP/2 a burst of 40 lookups of unique names takes 1.3–1.9 s over the two connections of the proxies; over HTTP/1.1 the first burst got 7 answers in 11.7 s. **Still to check:** the first boot of an image built weeks earlier. Without an RTC the clock starts from the build time or the newest file in `/etc`. If that is outside the validity of the DoH servers' certificates, TLS fails until NTP has set the clock, and NTP itself needs DNS ([TODO.md](TODO.md#checks-and-measurements)).

## 15. The 4pda thread

The [4pda thread of the Archer A5](https://4pda.to/forum/index.php?showtopic=964235), read in full on 2026-11-06: 48 pages, 954 posts from 2020-01 to 2026-11-05. It also covers the A5 v6. These are reports of users: unchecked, without a method, often without the firmware named. Posts are cited by number (`…&view=findpost&p=<number>`).

**Revisions of the hardware.**

* A5 v4, v4.2, v4.20 and C50 v4 are one device with one firmware (93090750, 95913551, 96633162, 138954237): the C50 v4 images of OpenWrt and Padavan install on all of them.
* A5 v6 / C50 v6: MT7628AN, MT7613BEN for 5 GHz (OpenWrt: `kmod-mt7615e`, `kmod-mt7663-firmware-ap`), the same RAM, an XMC XM25QH64 or Winbond W25Q64JVSIQ flash (138937176, 124588270). The OpenWrt images of the C50 v6 run on it (24.10.0 reported stable, 141870180, 144997818). A C50 v4 image boots on a v6 but without 5 GHz and is unstable (141870180). A v6 goes back to stock with the TP-Link file without its first 512 bytes (145088319). A v6 has no WPS LED (142254546); the TFTP recovery of the v4 waits for that LED.
* **Flash chips on the v4:** GigaDevice GD25Q64 (the unit of the tests, `c84017`), Winbond W25Q64 (an A5 v4, 2024: 132916772 on the photo of 132914707), cFeon QH64A-104HIP, i.e. EN25QH64A (an A5 RU v4.20 from 2019, 139572696). A guide of 2020 had the chip of its v4.2 missing from the CH341A list and used the W25Q64FW entry (101421749).

**The SPI clock against these chips** (datasheets; the build reads the flash with plain `Read Data` `03h`, since the device tree has no `m25p,fast-read`):

| Chip | JEDEC | `Read Data` (`03h`) up to | `Fast Read` (`0Bh`) up to |
|---|---|---|---|
| GigaDevice GD25Q64C (the unit of the tests) | `c84017` | 80 MHz | 120 MHz |
| Winbond W25Q64JV | `ef4017` | 50 MHz | 133 MHz (104 MHz at 2.7–3.0 V) |
| Winbond W25Q64FV | `ef4017` | 50 MHz (33 MHz at 2.7–3.0 V) | 104 MHz (80 MHz at 2.7–3.0 V) |
| cFeon (ESMT) EN25QH64A | `1c7017` | 50 MHz | 104 MHz |
| XMC XM25QH64C (A5 v6) | `204017` | 66 MHz | 133 MHz |

* **64.4 MHz is above the specification of the Winbond and cFeon chips for `03h`** (50 MHz). The test of [section 12](#12-tests-on-the-router) only shows that the GD25Q64 of the unit of the tests reads correctly. A unit with one of the other chips may read wrong data, depending on the chip and the temperature: squashfs errors (programs that crash) or, in the overlay, JFFS2 errors that can cost the settings. The other commands (status, write, erase) are specified up to 80–133 MHz on all of them.
* **Two clocks are within the specification of all five chips:**
  - **64.4 MHz with `m25p,fast-read`**: `0Bh` is specified up to 104 MHz or more on all of them, and spi-nor then sends one dummy byte per read. Ten MT7628 boards of the tree read their flash this way with `spi-mt7621`, among them the TP-Link Archer MR200 v5/v6 and TL-MR3020 v3 (50–58 MHz). It needs a test image (the property is read at probe) and `spitest.sh` on the unit of the tests.
  - **48.3 MHz (divider 4) with plain reads**: within 50 MHz; `spitest.sh` read at 2.05 MB/s instead of 2.22 MB/s at 64.4 MHz.
* 96.7 MHz with `Fast Read` would be within the specification of all but the W25Q64FV at 2.7–3.0 V, but the gain measured at it was small (2.43 MB/s) and the board was not tested there with `0Bh`.

**Installation and recovery** (adds to [section 1](#1-hardware-flash-layout-and-installation)):

* TFTP recovery: switch the firewall of the computer off (142294537); `tftpd64` shows the progress in its log tab (101616776); hold reset first, then power on (101616776). Padavan is installed by TFTP, not in the stock web interface; uploaded there it leaves the LEDs blinking (138837069, 138928589).
* After a TFTP flash of OpenWrt 25.12.5, one A5 accepted no older version: they flashed but did not boot, the power LED blinking or lit (144976222, 145003241). Unexplained. Another user had the reverse: 23.05.5 by TFTP left the power LED dark, 19.07 installed fine (134595184). A flash chip that older kernels do not know would explain the first case; this is a guess.
* Bricks are brought back with a CH341A and a full dump; a dump of another unit brings the other unit's MAC addresses and Wi-Fi calibration (138472848). One rescue needed a new network cable after the programmer (132977108).
* TP-Link has removed the RU firmware from its Russian site; the Kazakh site still has it (141121347, 144652894, 144653251); the thread's first post keeps the EN firmware for TFTP.

**Problems reported** (stock firmware unless stated):

* **Wi-Fi drops:** clients lose internet access while staying connected, most often on 5 GHz, on the stock firmware of every year (100119533, 103253570, 110983164, 141982488, 142371304); on 2.4 GHz up to 20 drops a day for one user (107035803); with an 80 MHz client almost unusable (100119533, 2020). OpenWrt 19.07.2–19.07.4 was worse there: both networks disappeared and the router rebooted (100119533). The first post (a 19.07 snapshot, 2020): 2.4 GHz no longer slowed down, 5 GHz no longer dropped (94344439).
* **2.4 GHz slow:** ≤10 Mbit/s for downloads on OpenWrt 22.03 on every device, 5 GHz fine (120710709, 2023); 5–20 Mbit/s on a PC (125345305, 2023, firmware not named); a smart TV at 5–6 Mbit/s while phones get 70–80 (141638331, 2026, A5 v4); the stock update of 2020 doubled the range of 2.4 GHz for one user and stopped its drops, not those of 5 GHz (103253570, 103985252).
* **Heat:** Wi-Fi losses and ping spikes under load, cured by heat sinks glued to the chips (110131495, 116454322, 127765131); 21.02 said to run hotter than 19.07 (112984489, 137494869).
* **Failing hardware:** units of v4.20 with a dead SoC (139572696, 142037761); spontaneous resets to the factory settings (142532226, 145067110), blamed on capacitors or the flash; a new power supply helped one user of another TP-Link, not the one here (141984440, 142372054).
* **LuCI slow** on OpenWrt 22.03.3: 30–40 s per page against 3–10 s on a TL-WR841N v4 (121058528, 2023). Consistent with the flash at 10 MHz and the memory pressure of [section 12](#12-tests-on-the-router).
* **WAN MAC address:** on OpenWrt 19.07 the override in LuCI did not take effect for some (94544290, 95397753, 108716086), for others it did (95416538) or worked after setting it over SSH (109214862). Russian ISPs often bind a contract to a MAC address.
* **Space:** free space on the official images: 19.07.9 about 3.6 MB, 21.02.7 about 2 MB, 24.10.2 about 1 MB (137917361); on 2024 OpenWrt the overlay did not hold the Russian translation (131838373). Users drop IPv6 to fit `pbr` and `dnsmasq-full` (145016747) or fit AmneziaWG with routing by an IP list (145062418).

**Speeds reported** (about 15 posts; almost all speedtests of a phone against a plan of 100 Mbit/s, so nothing above about 95 Mbit/s could show; no iperf, nothing between LAN and Wi-Fi or between two Wi-Fi clients; down / up in Mbit/s):

* Stock: 2.4 GHz 67 / 80 next to the router, 11.5 / 14 through two walls; 5 GHz 93 / 94 next to it, 26 / 41 through two walls (91002317, 2019). 5 GHz 80 both ways to a box at 2 m (91372748), about 95 both ways in a flat of 50 m² (100786167), 45 / 90 on a phone (95644529); 2.4 GHz 45 / 45 on phones at a plan of 70, 30 / 25 on a laptop at 5 m (96393789); the download half the upload at 20 and 40 MHz (95397753, 95418812); Wi-Fi about 50 against 90+ on the cable (134662498, 2025); 70–80 on a laptop and phone, 5–6 on a smart TV (141638331, 2026).
* OpenWrt: the 19.07 snapshot of the first post faster than stock, the download still 10 Mbit/s below the upload (95418812); 19.07.x 2.4 GHz 40–60 through a concrete wall, 60–80 on the cable (111088790); a laptop of 2008 at 3–4 / 15 on 2.4 GHz while other devices got 50+ (98195615); 22.03 2.4 GHz ≤10 during downloads (120710709). No numbers for 23.05, 24.10 or 25.12; 25.12.5 "seemed slow" (144976222).
* Padavan "clearly faster on Wi-Fi than any OpenWrt", without numbers (112460839).
* The download (the router sending to the client) below the upload shows up on the stock firmware and on OpenWrt of 2020 alike: the direction that is CPU-bound in mt76x02 on this build ([section 12](#12-tests-on-the-router)).

**What users want:** a VPN for chosen sites only (YouTube, Instagram) with a separate DNS for them (132756054, 145016747, 145062418); DPI circumvention, which a Padavan build offers (135280678, 140811156). Padavan (`padavan-ng`, `TPLINK_TL_C50-V4`) is the alternative the thread recommends in 2025–2026: "everything works, nothing drops" (143654641), though 5 GHz did not start for one user (134636953).

**Decisions for this build:**

* The SPI clock: the decision of 2026-11-05 holds only for the GD25Q64; since 2026-11-06 the clock is chosen by chip at boot ([section 12](#12-tests-on-the-router)). The test of 2026-11-06 ([section 12](#12-tests-on-the-router)): 96.7 MHz fails on the unit of the tests even with Fast Read, so 64.4 MHz is its highest clock, and the timing of the controller leaves the cFeon chip without a datasheet margin at 64.4 MHz.
* The README: the v4 only, how to tell a v6 (label; no WPS LED), the firewall of the computer for TFTP, a full dump first; a check of the WAN MAC override in LuCI before the release ([TODO.md](TODO.md#on-the-router)).
* The questions in the thread on 2026-11-05 about Wi-Fi speeds on other units had no answers yet.

## 16. The OpenWrt forum

The [porting thread of the Archer C50 v4](https://forum.openwrt.org/t/support-for-archer-c50-v4/20174) (119 posts, 2018-08 to 2020-01) and 30 other topics of the forum about the C50 v4 and A5 v4 (search for "c50 v4", "c50v4", "archer a5"; 2017–2026, about 520 posts), read on 2026-11-06 together with the C50 page of the wiki (last edited 2026-09-02). Topics are cited by number (`forum.openwrt.org/t/<number>`), posts by `#`.

**Hardware and firmware.**

* The C50 v4 is the C50 v3 (same PCB, FCC ID TE7C50V3, ESMT M14D5121632A); the difference is the split bootloader (20174 #7–#17). The A5 v4 and v4.20 run the C50 v4 images (96083, 24.10.2 with 2 MB free in 2025), and so does the C50 v5 / A5 v5 (53575 #138). The stock firmware is the same file for EU, BR and CA (wiki). The Mercury MAC1200R v2 is the same hardware (20174 #75).
* Flash: U-Boot of a C50 v3 reports `GD25Q64B` (`c84017`, 20174 #12); the wiki names a Winbond W25Q64BV as an example. Both fit [section 15](#15-the-4pda-thread): GigaDevice and Winbond in the same family.
* The stock firmware of the A5 v4 runs an SSH server that gives no shell (105195). The MT7628 has no temperature sensor that Linux can read (76423). A USB port can be soldered on and works with 22.03 (136564), outside what OpenWrt supports.
* The board name was `tplink,c50-v4` until 2021; a sysupgrade from such an image refuses the new name without `-F` (95439). The image of 25.12 lists the old name in `SUPPORTED_DEVICES`, so it is accepted.

**Installation and recovery** (adds to [section 1](#1-hardware-flash-layout-and-installation)):

* The TFTP recovery of the factory bootloader runs `tftp 0x80060000 tp_recovery.bin; erase tplink 0x20000 0x7a0000; cp.b 0x80080000 0x20000 0x7a0000` (155969 #11): it skips the first 128 KiB of the file and writes the rest from flash offset `0x20000`. That is why a recovery file for the v4 starts with 192 KiB of zeros, and why the stock file without its 512-byte header alone fails on the v4 (155969 #15; "TP-Link partially broke TFTP recovery with the v4", 20174 #17).
* Back to stock from OpenWrt: the stock file without its first `0x20200` bytes (the header and the second bootloader), installed with `sysupgrade` (20174 #77, #88; 46890 #30).
* Recovery failed with a TFTP server on Ubuntu and worked with `tftpd64` on Windows (20174 #63); bad cables and the firewall of the computer are the usual causes (155969 #10, 205754 #27). A router showing only the power LED after a flash may simply run OpenWrt with Wi-Fi off and wait at 192.168.1.1 (205754).
* A flash wiped or written without its `radio` partition loses the calibration for good: 5 GHz then fails, the advice is a calibration of a unit with a close serial number at best (222057, 222340, 45538 #6).

**Wi-Fi problems on OpenWrt, by release:**

* **2.4 GHz range** (2020 to 19.07.6): some units lost the connection a few metres away, 1 Mbit/s or less on 2.4 GHz; the stock firmware reached 5.5 times the distance (53575 #27). Cause: `0x7600` as the chip ID in the EEPROM, which `mt7603_check_eeprom()` rejected, so the driver ran on default calibration (53575 #49). Fixed in 19.07.7 (mt76 pull 442/491); already in [section 1](#1-hardware-flash-layout-and-installation). One A5 v4.20 still had poor 2.4 GHz with the patched image (53575 #87–#89), unexplained.
* **Reboots with 12–15 or more Wi-Fi clients** on 19.07.4, from a regression of `mtk_soc_eth`; fixed in 19.07.5 (53575 #92–#104). Random reboots every few days on 19.07.4 stopped with 19.07.7 (53575 #133, #147). A weak power supply was suggested, not shown (53575 #99).
* **DFS channels of 5 GHz did not start** (19.07, 2020–2021): 52–64 and 100–140 left the radio "not associated"; 36–48 and 149–165 worked, and a change away from 36 needed a reboot (53575 #94–#95, #139–#146).
* **2.4 GHz stops under heavy traffic** until a reboot, 5 GHz fine: 21.02.3 and 22.03.0-rc4 (53575 #155); after about 12 hours on 21.02.1 (117508), "after some hours" on 21.02.1 (114414). This looks like the hang of mt7603 under load seen on 2026-11-03 ([section 12](#12-tests-on-the-router)).
* **Speed:** after 24.10 "both ways dropped from 95 to 60–70 Mbit/s" (117508 #3, 2025); 2.4 GHz 18 Mbit/s on 21.02-rc2 (53575 #150); memory leak after 30 days and a slower LuCI on 21.02 (53575 #154); 5 GHz capped at 17 dBm on one release (53575 #119); random 2.4 GHz disconnects on every firmware for one user (53575 #134).
* **The C50 v4 as a 5 GHz client** (WISP, relayd or routed client, 2019): uploads of 0.2–2 Mbit/s while other devices on the same network got 80 (46890); reproduced on MT7621 routers with relayd (46890 #33–#35).
* **The A5 v6** (other hardware) stopped answering authentication requests after 1–7 days until a reboot, with nothing in the logs (165221, 2023). The SAE retries of the phone on 2026-11-03 ("did not acknowledge authentication response") are another symptom on another radio; kept in mind.

**Performance of mt76 against the MediaTek driver** (5731, 2017, LEDE, iperf3; the router is not named, its author used an MT7621 and an MT7628 board): router receiving 342 Mbit/s (one stream) / 623 (eight) with mt76 against 301 / 483 with the MediaTek driver; router sending 51 Mbit/s with mt76 against 280 / 477. The MT7603: receiving 75 / 94 against 101, sending 35 against 38 / 44. mt76 has changed much since (in December 2017 an MT7621 router sent 250 Mbit/s with it at VHT40), but the direction that was weak then is the one that is CPU-bound on this router now ([section 12](#12-tests-on-the-router)).

**OpenVPN:** about 12 Mbit/s over Ethernet and 9.6 over Wi-Fi on a 2019 snapshot (20174 #116). The WireGuard measurement of this build is still to come ([TODO.md](TODO.md#on-the-router)).

**Decisions for this build:**

* Checks on the router added to [TODO.md](TODO.md#on-the-router): a DFS channel on 5 GHz, the WISP upload, and the 2.4 GHz hang under heavy TCP traffic, which the forum reports on 21.02 and 22.03.
* The README: a router with only the power LED lit after the installation is probably fine (Wi-Fi of the official images is off, this build turns it on); TFTP from Windows with `tftpd64`.

## Sources

* Datasheets of the flash chips: [GigaDevice GD25Q64C](https://www.espruino.com/datasheets/GD25Q64C.pdf), [Winbond W25Q64JV](https://static.chipdip.ru/lib/072/DOC006072803.pdf), [Winbond W25Q64FV](https://datasheet.sic-components.com/W25Q64FV.pdf), [ESMT (cFeon) EN25QH64A](https://endrich.com/Datenbl%C3%A4tter/Aktive%20Komponenten/EN25QH64A%282AC%29.pdf), [XMC XM25QH64C](https://www.xmcwh.com/uploads/207/XM25QH64C.pdf)
* [OpenWrt Table of Hardware: TP-Link Archer C50](https://openwrt.org/toh/tp-link/archer-c50), [DeviWiki: TP-LINK Archer C50 v4.x](https://deviwiki.com/wiki/TP-LINK_Archer_C50_v4.x), [OpenWrt wiki: IPTV / UDP multicast](https://openwrt.org/docs/guide-user/network/wan/udp_multicast)
* [4pda: TP-Link Archer A5](https://4pda.to/forum/index.php?showtopic=964235): [OpenWrt installation and back to stock](https://4pda.to/forum/index.php?showtopic=964235&view=findpost&p=94344439), [full dump of an A5 v4](https://4pda.to/forum/index.php?showtopic=964235&view=findpost&p=104398753), [recovery with a programmer](https://4pda.to/forum/index.php?showtopic=964235&view=findpost&p=101421749)
* OpenWrt Forum: [Support for Archer c50 v4](https://forum.openwrt.org/t/support-for-archer-c50-v4/20174), [Archer C50 v4 loses internet access after 20' away from the router](https://forum.openwrt.org/t/archer-c50-v4-mac80211-loses-internet-access-after-20-away-from-router-but-maintains-connection/53575), [C50 V4 upload speed issue](https://forum.openwrt.org/t/tp-link-archer-c50-v4-upload-speed-issue-almost-0-mbps/46890), [Benchmark of mt76 and the MediaTek driver](https://forum.openwrt.org/t/bechmark-results-between-mt76-open-source-and-stock-mediatek-on-mt7612e-and-mt7603e/5731), [Firmware update gone bad Archer A5 v4](https://forum.openwrt.org/t/firmware-update-gone-bad-archer-a5-v4/155969), [Hard bricked Archer A5 v4.2](https://forum.openwrt.org/t/hard-bricker-archer-a5-v4-2/222057), [Archer C50 V4 EU – Cannot install OpenWrt](https://forum.openwrt.org/t/archer-c50-v4-eu-cannot-install-openwrt/253206), [Multicast IPTV over wireless](https://forum.openwrt.org/t/multicast-iptv-over-wireless-but-without-client-isolation-possible/111776)
* [Images, ImageBuilder and SDK of OpenWrt 25.12.6 for ramips/mt76x8](https://downloads.openwrt.org/releases/25.12.6/targets/ramips/mt76x8/)
* [openwrt/mt76](https://github.com/openwrt/mt76) (fixes after `39c960c3`)
* OpenWrt: [GCC 15.3.0 in main](https://github.com/openwrt/openwrt/commit/97424f9c860593ad524aff84a2f982b97abfed5f), ["build: always set CONFIG_IPV6"](https://github.com/openwrt/openwrt/commit/832e7b817221d288df76b763ca12c585365db5d8), ["ramips: add support for Archer C50 v4"](https://github.com/openwrt/openwrt/commit/01dcd574a24864c10a9c4df4304a3ce0da5c11a9)
* Linux 6.12.112: [`net/netfilter/Kconfig`](https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git/tree/net/netfilter/Kconfig?h=v6.12.112), [`arch/mips/Kconfig`](https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git/tree/arch/mips/Kconfig?h=v6.12.112)
* [AmneziaWG for OpenWrt](https://github.com/Slava-Shchipunov/awg-openwrt), [https-dns-proxy](https://github.com/aarond10/https_dns_proxy) and its [OpenWrt package](https://github.com/openwrt/packages/tree/master/net/https-dns-proxy)
* GCC: `gcc/config/mips/mips-cpus.def` of GCC 15.2.0
