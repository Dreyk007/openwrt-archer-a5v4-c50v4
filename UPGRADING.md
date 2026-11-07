# Upgrading to a New OpenWrt Release

This document describes how to move the `a5v4-25.12` branch of this repository to a new OpenWrt release:

* [Minor release](#2-minor-release-eg-25126--25127) — a new point release of the same series (e.g. 25.12.6 → 25.12.7). Done by **merging** the new upstream tag.
* [Major release](#3-major-release-eg-2512--26xx) — a new release series (e.g. 25.12 → 26.xx). Done by creating a **new branch** from the new upstream tag and **porting** (cherry-picking) the fork's commits.

Before an update, read [TODO.md](TODO.md): it lists the fork's patches to drop once upstream has the fix, and the deferred candidates to look at with a new release.

Unlike the AX3200 build this one does not use the official package repository or its kernel modules, so there is no vermagic to follow and no kernel configuration parity to keep. Instead, every update has to keep the kernel configuration of this build intact ([2.5](#25-build-and-check-the-kernel-configuration)), pass the QEMU bench and fit the flash and RAM budget ([Appendix B](#appendix-b-flash-and-ram-budget-check)).

**Contents:** [1. What the branch consists of](#1-what-the-branch-consists-of) · [2. Minor release](#2-minor-release-eg-25126--25127) · [3. Major release](#3-major-release-eg-2512--26xx) · [Appendix A](#appendix-a-simulating-a-merge-without-touching-the-working-tree) · [Appendix B](#appendix-b-flash-and-ram-budget-check) · [Appendix C](#appendix-c-on-device-verification)

---

## 0. Prerequisites

```bash
# Remotes: origin = this fork, upstream = official OpenWrt
git remote -v
git remote add upstream https://github.com/openwrt/openwrt.git   # only if it is missing

# Start from a clean working tree
git status

# git >= 2.38 is needed for "git merge-tree --write-tree" (Appendix A)
git --version
```

Release tags of this build follow the scheme `v<openwrt-version>-a5v4-r<N>`, e.g. `v25.12.6-a5v4-r1`.

---

## 1. What the Branch Consists Of

`a5v4-25.12` = upstream release tag **`v25.12.6`** **+** the initial commit of the GitHub repository (merged once with `--allow-unrelated-histories`) **+** this build's commits.

```bash
BASE=v25.12.6                                                 # upstream tag the branch is based on
git log --oneline --no-merges $BASE..a5v4-25.12               # this build's commits
git log --oneline --first-parent $BASE..a5v4-25.12            # including the merges
```

### 1.1. This build's commits

**New files** (cannot conflict with upstream):

| File | Purpose |
|---|---|
| `LICENSE` | GPL-2.0 text from the initial commit of the GitHub repository, so that GitHub shows the license; OpenWrt's own are `COPYING` and `LICENSES/` |
| `build.sh` | Build script after the one of openwrt-ax3200, without vermagic, BPF toolchain and update check: feeds (every feed restored to its commit, then `feeds-patches/<feed>/*.patch`), the seed (`--seed`, default `a5v4.config`) or the same seed for the QEMU bench (`--qemu`: malta/le with `mac80211_hwsim`, `pcnet32` and the Wi-Fi drivers of the router), `--profile hybrid|o2` (the compiler flags of the programs: OpenWrt's `-Os` with MIPS16, or `-O2 -march=24kec -mtune=24kec` without MIPS16; [RESEARCH.md section 5](RESEARCH.md#5-compiler-and-flags)), `--ccache`, `--dev` (a debug image for diagnostics on the router, never released: debugfs, kernel symbols, SysRq, perf events, tracepoints, hung task, soft lockup and workqueue stall reports, `TRIM_UNUSED_KSYMS` off, `kprof`, `udpblast`, `ethtool` and `iperf3` in the image (`package/utils/a5v4-diag`), `perf`, `tcpdump` and `strace` as packages for `/tmp`, no AmneziaWG; [AGENTS.md](AGENTS.md#building-and-testing)), the kernel fragment `a5v4-kernel.config` → `env/kernel-config` (with the hash of `a5v4-ksyms.txt`, so that a changed whitelist configures the kernel again), a clean target build (`make clean`) when the toolchain or the global compiler flags of the programs change (`build_dir/a5v4-build-key`), `SOURCE_DATE_EPOCH` from the last commit, a check that every package of the image is selected and every busybox link names an applet of the build (otherwise the packages that pull in others, or busybox, are built again), a size report (`bin/targets/*/size-report.txt`), two kernel checks that stop the build (every line of the fragment is in the final kernel configuration; every symbol that a module of the image takes from the kernel is exported, `kernel-symbols.txt`; modpost only warns, `KBUILD_MODPOST_WARN=1`, so that a module built outside the kernel tree that needs a symbol missing from the whitelist reaches this check instead of stopping the build before the list exists) and `sha256sums` |
| `a5v4-kernel.config` | Kernel configuration fragment: the modules the image always loads built in (the VPNs stay modules, loaded when a tunnel is created), the approved options off ([RESEARCH.md section 3](RESEARCH.md#3-size-of-the-kernel)), `TRIM_UNUSED_KSYMS` with the whitelist |
| `files/etc/uci-defaults/99-a5v4-defaults` | Defaults of the first boot, once per configuration (marker `a5v4.defaults.applied` in `/etc/config/a5v4`, which sysupgrade keeps): software flow offloading, `drop_invalid`, SSH (`dropbear` `Interface`) only on the LAN, the WAN zone and the global defaults drop (input and forward, only from the stock `REJECT`; `Allow-Ping` stays), the NTP server on. DoH as in openwrt-ax3200, with a marker of its own (`a5v4.defaults.doh`): `https-dns-proxy` `dnsmasq_config_update '*'`, `force_dns '0'`, `conn_loss_time '30'`. |
| `files/etc/init.d/a5v4-threaded-napi` (new) | Threaded NAPI on `eth0`, which netifd has no option for: writes 1 to `/sys/class/net/eth0/threaded` at every boot (`START=11`, after the boot script has loaded the modules); `a5v4.network.threaded_napi '0'` and `start` turn it off. An init script, not a hotplug script: the built-in driver creates `eth0` before procd starts, and procd's coldplug announces only devices with a device node, so no `add` event of `eth0` ever reaches `/etc/hotplug.d/net` on the router (on QEMU's malta `eth0` is a module and gets one). Goes together with GRO off (patch 601 below; [RESEARCH.md section 12](RESEARCH.md#12-tests-on-the-router)) |
| `target/linux/generic/hack-6.12/601-net-leave-GRO-off-on-new-network-devices.patch` (new) | `register_netdevice()` turns on GSO for a new network device but not GRO, so every interface starts without GRO: `eth0`, every Wi-Fi interface (access points, a guest network, the client of travelmate), the tunnels of WireGuard and AmneziaWG. GRO stays changeable: a device section with `option gro '1'` (netifd) or `ethtool` turns it on, with fraglist (patch 600 of OpenWrt). Without TX checksums and segmentation in hardware, GRO costs this router more than it saves ([RESEARCH.md section 12](RESEARCH.md#12-tests-on-the-router)). A generic patch, so the QEMU build has it too. Refresh it when `register_netdevice()` changes; not for upstream (a choice of this build) |
| `a5v4-ksyms.txt` | Whitelist of `TRIM_UNUSED_KSYMS`: the symbols that the modules of the image take from the kernel (those built outside the kernel tree need it: mac80211, mt76, `amneziawg`, `mac80211_hwsim` of the bench); the union of `kernel-symbols.txt` of the router and of the QEMU build |
| `package/kernel/mt76/patches/0300-*.patch` … `0322-*.patch` | 22 fixes of `openwrt/mt76` master for mt7603, mt76x02/mt76x2 and the common code these drivers call (each says `cherry picked from commit …`), in upstream order, and `0322` the own fix of the mt7603 dynamic sensitivity ([RESEARCH.md section 6](RESEARCH.md#6-wi-fi-driver-fixes-from-mt76-master)). Drop each one the mt76 of a new release contains ([2.2](#22-merge-the-new-tag)) |
| `package/kernel/mt76/patches/0323-*.patch` … `0327-*.patch` (new, 2026-11-06/07) | Three open pull requests of `openwrt/mt76` for mt7603, not merged when taken (each names its PR): `0323` #1166 queues the watchdog work after a failed channel switch instead of calling it with `dev->mutex` held (the deadlock of the 2.4 GHz radio, [TODO.md](TODO.md#on-the-router)), `0324` #941 sets the EDCA parameters again after a change of the slot time, `0325` #1136 reports RSSI from RCPI instead of IBRssi and drops the EEPROM RSSI offsets. `0326` own: the module parameter `delay_int` of `mt76x02_lib` (written to `MT_WPDMA_DELAY_INT_CFG` at `wifi up`; 0x9032880a by default since 2026-11-07, 0 turns it off) uses the delay interrupts of the WPDMA in place of the per-frame ones; the interrupt handler acks the raw status (from PR #1138), and the unused TX setting of the init table of mt76x2 goes. `0327` own: the same parameter for `mt7603e` (`MT_DELAY_INT_CFG`; its status bits 22 and 23, found on the router, are in no header), on by default, and written again by the watchdog reset. Drop 0323–0325 when mt76 has them; 0326 and 0327 need `param_ops_uint` in `a5v4-ksyms.txt` |
| `docker/Dockerfile`, `docker/run.sh` | Build container (Debian testing) with the prerequisites of the OpenWrt build and the tools of the QEMU bench. `run.sh` rebuilds the image when the Dockerfile changes and runs a command with the checkout at `/work`: as the owner of the checkout, or as root with network rights inside the container (`--bench`) |
| `reference.config` | The official build configuration of 25.12.6 (`config.buildinfo` of ramips/mt76x8) reduced to `tplink_archer-c50-v4`: the reference for size comparisons |
| `a5v4.config` | Seed of this build, written with `scripts/diffconfig.sh`; it starts as `reference.config` and follows the plan of [TODO.md](TODO.md#first-release) |
| `tests/router/router-bench.sh` | Measurements on the router for the A/B of the profiles: memory and private memory of the daemons, idle CPU, timed runs of busybox, ucode, `jsonfilter`, `ubus`, `uci`, `wg` and `nslookup` on the same input in both profiles, and the timeline of the last boot from `dmesg` and `logread`. Depends on the log messages it looks for (preinit, procd, `rt3050-esw`, `br-lan`, netifd) |
| `tests/router/luci-bench.sh` | Server-side timing of LuCI on the router for the A/B of the profiles: the HTML of the Overview page and the ubus calls of the Overview, Wireless and Firewall pages in one JSON-RPC batch each, through uhttpd with a temporary session that has root's rights (created over ubus, no password), plus `MemAvailable` and the memory of uhttpd and rpcd. Depends on the paths and ubus methods of LuCI's views and on the session check of `dispatcher.uc` (access groups by name) |
| `tests/router/kprof.c` (new) | A system-wide CPU profiler of 14 KB for the debug image (`build.sh --dev`): samples through `perf_event_open` (CPU cycles, cpu-clock as a fallback) from its start and names the samples afterwards, so that a CPU busy with traffic delays only the report; prints the share of each kernel function with its main callers and of each process, the CPU time by kind and the traffic of every interface over its window, and how late its own 100 ms timer ran (how long a process at normal priority waits for the CPU). `perf` takes 6 MB of RAM in `/tmp`, which pushes the debug image into re-reading the flash. The static functions of modules are stripped, so it can write the module samples as module+offset for `modsym.py`. Built with the toolchain of the build tree (AGENTS.md) or by `package/utils/a5v4-diag`. |
| `tests/router/udpblast.c` (new) | UDP load from the router to a client for Wi-Fi tests: datagrams of one size to an address for a time, as fast as the stack takes them or at a rate; an unconnected socket, so that ICMP port unreachable does not fail the sends. |
| `tests/router/udptest.sh` (new) | UDP from the router to one Wi-Fi client (`udpblast`) while `kprof` samples: rate on the interface, retries and failures of the station, channel survey, flash reads and page refaults, CPU. |
| `tests/router/dbglog.sh` (new) | Read-only log of the debug image every few minutes: sensitivity and false CCA of mt7603, aggregation of both radios, the AGC of mt76x2, and per station the power save flag, filtered frames, counters and the best rates of minstrel. Depends on the debugfs files of mt76 and mac80211. |
| `tests/router/hangload.sh` (new) | Width switches of the 2.4 GHz radio (HT40 with and without the coexistence scan, HT20) while a UDP stream keeps the TX queues full, to catch the mt7603 hang (TODO.md); collects the stacks of stuck tasks and SysRq `w`. The configuration file goes back to the original after each switch. |
| `tests/router/abwatch.sh` (new) | Profiles of real traffic without anybody at the site: when the CPU is busy, `kprof` samples for 20 s with the traffic counters, while GRO on `eth0` and both radios takes the next of three states (with fraglist, without fraglist, off); back to the default at the end. Needs `ethtool` in `/tmp`. |
| `tests/router/spitest.sh` (new) | Read test of the SPI flash at higher clocks through `test_speed_hz` (below), or with `-r` through `test_read_speed_hz` (the Fast Read alone): the partitions that do not change, everything but `rootfs_data`, read at the device tree's clock for reference and then several times at each test clock, compared by SHA-256, and the raw read rate of `rootfs` at each clock; read-only. |
| `tests/router/labtest.sh` (new) | Router side of the iperf3 tests with clients at the site: in a 240 s cycle that the clients keep by the clock, one state per cycle (A: GRO with fraglist and flow offloading, B: GRO without fraglist, C: no GRO, D: no flow offloading without a commit, T: threaded NAPI on `eth0`, U: no GRO and threaded NAPI), and `kprof` from 2 s before each client's run for 22 s, at absolute times (a run that saturates the CPU can starve the script itself for many seconds); module samples per run for `modsym.py`; back to the default at the end. |
| `tests/router/iperf-pc.ps1` (new) | iperf3 client loop for a Windows PC with both a cable and Wi-Fi to the router: download and upload over the cable at 0 and 30 s, over Wi-Fi at 60 and 90 s of the cycle, bound to each adapter's address, to ports 5201 and 5202 of an iperf3 server on the internet. |
| `tests/router/iperf-phone.sh` (new) | The same for an Android phone in Termux: download and upload at 120 and 150 s of the cycle, to port 5203. |
| `tests/router/wifitest.sh` (new) | Router side of the tests with a phone running `iperf-phone.sh`: in its 240 s cycle UDP to the phone (`udptest.sh`), iperf3 of the router through the WireGuard tunnel up and down, `kprof` (or, with `KPROF=none`, only the CPU and traffic from `/proc`) over the phone's runs with its retries and failures; one state per cycle as in `labtest.sh`; with `REVIVE=1` both radios go down for 45 s after a cycle whose download moved less than 5 MB, which frees a hung iperf3 on the phone. |
| `tests/router/grocheck.sh` (new) | Checks that netifd's `gro` device option reaches `eth0` and the Wi-Fi interfaces: device sections with `gro 0`, a restart of the network, `wifi up radio0`, the original configuration back; reboots with the original if the router stays offline 5 minutes. |
| `tests/router/hangtcp.sh` (new) | Width switches of the 2.4 GHz radio 8 s into the phone's TCP download and upload (the mt7603 hang), only when the radio sends at least 5 Mbit/s; the evidence to `/root`, an optional reboot after a hang. |
| `tests/router/bandswitch.sh` (new) | Moves a phone between the 2.4 and 5 GHz access points (the radio it is on taken down, or a deauthentication with a ban) and logs the time of each move and hostapd's steps (SAE, 4-way handshake, DHCP). |
| `tests/router/unstick.sh` (new) | Answers the retransmissions of a phone's hung iperf3 control connection with a TCP reset, from an nftables table of its own. |
| `tests/router/irqlab.sh` (new) | Router side of the A/B tests with clients at the site: one state per 240 s cycle of `iperf-pc.ps1` and `iperf-phone.sh` (N, E, W: the delay interrupts of `eth0` and of the MT7612E), `kprof` and the interrupts per second over each run, UDP from the router to a phone in slot 0. |
| `tests/router/modsym.py`, `tests/router/modlines.py` (new) | Host side: name the module samples of `kprof` per function (`modsym.py`) and per source line (`modlines.py`, `addr2line` of the toolchain) with the unstripped `.ko` of the build tree. The run-time address of each section comes from the global functions that `/proc/kallsyms` of the router lists; the modules of the tree must be those of the image (compare the `.text` of the router's copy). They need pyelftools: run them in the build container. |
| `package/utils/a5v4-diag/Makefile` (new) | The package of the debug image's own tools: `kprof` and `udpblast` built from `tests/router`, and the scripts of `tests/router` in `/usr/share/a5v4-diag`. Only `build.sh --dev` selects it. |
| `target/linux/ramips/patches-6.12/950-spi-mt7621-add-a-test-clock-parameter.patch` (new) | `spi-mt7621`: the parameter `test_speed_hz` (`/sys/module/spi_mt7621/parameters/`) runs every transfer at that clock instead of the device tree's, so that a faster flash clock can be tried on a running system (`tests/router/spitest.sh`) before a device tree is built with it; `test_read_speed_hz` does the same for messages with dummy bytes only (the Fast Read with `m25p,fast-read`), so status and write commands keep a clock the flash allows for them. 0, the default, changes nothing. Refresh it when the driver changes. |
| `target/linux/ramips/dts/mt7628an_tplink_archer-c50-v4.dts` | The SPI flash at 48.3 MHz for any chip (`spi-max-frequency` 50 MHz: the bus clock of 193.3 MHz divided by 4) instead of the 10 MHz of `mt7628an_tplink_8m*.dtsi`, within the datasheets of every chip known on these boards; 64.4 MHz (`openwrt,fast-frequencies`) for any chip that passes a read check at boot (patch 951). The GD25Q64 of the test unit read back the same at 64.4 MHz; 96.7 MHz corrupted reads, with Fast Read too ([RESEARCH.md section 12](RESEARCH.md#12-tests-on-the-router)). The boot and every page the kernel reads again from squashfs wait less on the flash. |
| `target/linux/ramips/patches-6.12/951-mtd-spi-nor-a-faster-clock-after-a-read-check-at-boot.patch` (new) | spi-nor: the flash node's `openwrt,fast-frequencies` (highest first): the chip reads the first 128 KiB at `spi-max-frequency`, then twice at each clock, and keeps the first clock whose reads are equal, before its partitions are registered; if none passes it keeps `spi-max-frequency`. The optional `openwrt,fast-flash` (pairs of JEDEC ID and CRC-32 of the SFDP, 0 for any) limits it to listed chips; this board does not use it. `dmesg` logs the chip (JEDEC ID, SFDP CRC-32) and its clock. Not for upstream as it is (a vendor-neutral binding would be needed). |
| `tests/qemu/bench.sh` | QEMU bench: the malta/le image with `-cpu 24KEc -m 64`, the root file system on a virtual disk, a LAN client and a WAN side (DHCP, DNS, an internet host) in network namespaces, and the checks of [TODO.md](TODO.md#build-and-qemu) |
| `README.ru.md`, `TODO.md`, `UPGRADING.md`, `RESEARCH.md` | Documentation |
| `AGENTS.md`, `CLAUDE.md` | Guidance for coding agents; `CLAUDE.md` only imports `AGENTS.md` for Claude Code |

**Edits of upstream files** (possible conflict points):

| File | Change |
|---|---|
| `README.md` | Replaced: a placeholder with the language switch until the first release |
| `.gitignore` | `/files` removed: the build's `files/` (copied into the image) is tracked |
| `target/linux/ramips/files/drivers/net/ethernet/ralink/esw_rt3050.c` | The ports that `mediatek,portmap` leaves out of the LAN (the WAN port) stay disabled from a reset of the switch until userspace applies a configuration (`wan_isolated`, `esw_apply_user_config()`); before, the empty configuration bridged WAN and LAN from the probe until preinit and netifd configured the switch. Conflicts when upstream edits `esw_hw_init()`, `esw_set_port_bool()` or the ops of the driver; drop it once upstream isolates the WAN port itself |
| `target/linux/ramips/files/drivers/net/ethernet/ralink/mtk_eth_soc.c`, `mtk_eth_soc.h`, `ethtool.c` | `ethtool -C` for the frame engine: `rx-usecs`/`rx-frames` and `tx-usecs`/`tx-frames` set the delay interrupt (`FE_REG_DLY_INT_CFG`, the time in steps of 20 µs), and NAPI then enables the delay interrupt of that direction in place of its done interrupt; the default `FE_DLY_INT_DEFAULT` is 200 µs or 16 frames received and 200 µs or 32 sent since 2026-11-07, 0 is the old behaviour (2026-11-06, [RESEARCH.md section 8](RESEARCH.md#8-routing-acceleration-and-iptv)). Conflicts when upstream edits `fe_handle_irq()`, `fe_poll()`, `fe_hw_init()`, `fe_open()` or `fe_stop()`; drop it if the target moves to the mainline `mtk_eth_soc`, which moderates its interrupts itself |
| `toolchain/gcc/Config.version`, `toolchain/gcc/common.mk`, `toolchain/gcc/patches-1[345].x/` | GCC 15 updated to 15.3.0 by three commits of OpenWrt main, cherry-picked with `-x`: `d8458334a7` (drop `110-Fix-MIPS-PR-84790.patch`), `59c07e6053` (disable the TM clone registry with a configure option instead of a patch), `97424f9c86` (15.3.0). `a5v4.config` selects GCC 15 (`CONFIG_TOOLCHAINOPTS`, `CONFIG_GCC_USE_VERSION_15`). Conflicts when 25.12 changes GCC itself; drop the three commits once the series builds 15.3.0 or newer by default |
| `package/kernel/mt76/Makefile` | `PKG_RELEASE` 4 instead of upstream's 3, so that the packages with the `03xx` patches differ from the official ones. Conflicts when upstream updates mt76; take upstream's version and set `PKG_RELEASE` one higher |
| `package/utils/ucode/Makefile` | `PKG_BUILD_FLAGS:=no-mips16`: ucode, on which LuCI runs, in full MIPS32 code also in the `hybrid` profile (+10 KiB of `root.squashfs`). Conflicts when upstream edits the header of the Makefile; drop it if the build leaves MIPS16 altogether |
| `package/kernel/mac80211/Makefile` | Kconfig `PACKAGE_MAC80211_ENABLE`, `_COUNTRY`, `_SSID`, `_ENCRYPTION`, `_PASSWORD` (remittor, ported from openwrt-ax3200 `5b3ea79096`); `a5v4.config` sets Wi-Fi on, country PA, `psk2+ccmp` and the password `12345678`. Conflicts when upstream edits the config block of `kmod-mac80211` |
| `package/base-files/Makefile` | Substitutes these options into `77_wireless` and lists them in `PKG_CONFIG_DEPENDS` (openwrt-ax3200 `5b3ea79096`, `75f48c71a9`), so that a changed default rebuilds `base-files` |
| `package/base-files/files/etc/uci-defaults/77_wireless` (new in the tree, from the same commits) | On the first boot: both radios and their access points on, the country, per band 2.4 GHz on channel 1 with `HT20` and 5 GHz on channel 36 with `VHT80` (no DFS), SSID `<board>-<band>-<radio><4 hex digits of the MAC>`, the password of the seed: WPA2 on 2.4 GHz, WPA2/WPA3 mixed mode (`sae-mixed`) on 5 GHz where `hostapd -vsae` reports SAE (`wpad-basic-mbedtls`) |
| `feeds-patches/packages/0001-https-dns-proxy-keep-the-backup-of-an-empty-dnsmasq-server-list.patch` (new) | https-dns-proxy backs up the server list of dnsmasq once, as one empty entry when dnsmasq has none (the default); the next start took that entry for a missing backup and backed up the proxy addresses, so stopping or disabling DoH put them back into dnsmasq. The fix tests that the backup exists, as the restore does ([RESEARCH.md section 14](RESEARCH.md#14-encrypted-dns-doh)). `build.sh` applies it after `feeds update`; it stops the build when it no longer applies. Upstream master (2026.05.06-r1) still has the bug |
| `feeds.conf.default` | The feed `amneziawg` ([awg-openwrt](https://github.com/Slava-Shchipunov/awg-openwrt)) pinned to a commit: `kmod-amneziawg`, `amneziawg-tools`, `luci-proto-amneziawg` ([RESEARCH.md section 13](RESEARCH.md#13-vpn-wireguard-and-amneziawg)). Conflicts when upstream edits the feed list |
| `package/kernel/linux/modules/netsupport.mk` | `kmod-wireguard` without `AUTOLOAD`: the module loads when netifd creates a WireGuard interface (`ip link add … type wireguard` asks the kernel for `rtnl-link-wireguard`), not at boot. Conflicts when upstream edits `KernelPackage/wireguard` |

### 1.2. Planned changes

The plan of the first release ([TODO.md](TODO.md#first-release)). When one lands, move it to the tables of 1.1 with its exact files.

| Change | Files | Conflict risk |
|---|---|---|
| Release workflow | `.github/workflows/build-a5v4.yml` (new) | none |

---

## 2. Minor Release (e.g. 25.12.6 → 25.12.7)

Expected effort: **few conflicts**, at the edits of 1.1 and 1.2. A simulation on 2026-10-31 merged `upstream/openwrt-25.12` (25 commits after `v25.12.6`) into the branch without conflicts; the branch held only the documentation then.

Below, `NEW=25.12.7` and `OLD=25.12.6`.

### 2.1. Preview the merge (does not change anything)

```bash
git fetch upstream --tags
git merge-tree --write-tree --name-only HEAD v$NEW
echo $?        # 0 = clean merge; 1 = conflicts, the conflicted files are listed after the first line
```

### 2.2. Merge the new tag

The branch is published, so merge instead of rebasing:

```bash
git switch a5v4-25.12
git tag backup/pre-v$NEW                                   # local safety point
git merge --no-ff v$NEW -m "Merge tag 'v$NEW' into a5v4-25.12"
```

Merge release tags, not the branch head: a tag is what OpenWrt built and tested as a whole. The build does not depend on the official kmods, so a fix of `openwrt-25.12` that should not wait for the next release can be taken with `git cherry-pick -x` in between; list it in [TODO.md](TODO.md) until the release brings it.

If a conflict happens anyway:

* `README.md` — keep ours (`git checkout --ours README.md`); upstream only has the generic OpenWrt README.
* Makefiles / scripts — keep both changes: take upstream's version and re-apply the fork's lines (see [1.1](#11-this-builds-commits)).
* `package/kernel/mt76/Makefile` — take upstream's version and set `PKG_RELEASE` one higher than upstream's, so the packages with our `03xx` patches differ from the official ones.
* `git add <file>` for each resolved file, then `git commit`.

If the new release changed `package/kernel/mt76` (a new Git HEAD or more fixes cherry-picked), drop the `package/kernel/mt76/patches/03xx-*.patch` that it now contains: compare their `Subject:` lines with the new upstream patches (subjects may be wrapped over two lines) and, after a Git HEAD update, check with `git -C <mt76 clone> merge-base --is-ancestor <commit> <new PKG_SOURCE_VERSION>` (each `03xx` patch names its upstream commit). Then run `make package/kernel/mt76/{clean,compile} V=s` and make sure every remaining `03xx` patch still applies.

Check the version: `grep -nF '$(VERSION_NUMBER),$(VERSION_NUMBER),' include/version.mk` must show the new version number.

### 2.3. Update the feeds

The release commit pins new feed revisions in `feeds.conf.default`:

```bash
./scripts/feeds update -a
./scripts/feeds install -a
```

A new feed revision can change travelmate, https-dns-proxy or the LuCI apps; check their dependencies (e.g. travelmate's `curl` and `ca-bundle`) against [RESEARCH.md section 10](RESEARCH.md#10-what-the-image-leaves-out).

### 2.4. Re-validate the seed configuration

```bash
cp a5v4.config .config && make defconfig
./scripts/diffconfig.sh > /tmp/a5v4.config.new
diff a5v4.config /tmp/a5v4.config.new
```

No output means nothing changed. Otherwise review the difference (renamed/removed packages or options, a package the image left out coming back as a dependency), then `cp /tmp/a5v4.config.new a5v4.config`. Never edit the seed by hand.

### 2.5. Build and check the kernel configuration

```bash
docker/run.sh ./build.sh --ccache       # in the build container; ./build.sh alone on a prepared host
```

A kernel version bump can rename or drop options of the kernel fragment, and OpenWrt's own options win over it. `build.sh` stops when a line of the fragment is not in the final configuration (the QEMU build only warns: malta lacks the LEDs and the USB PHY of the router). New options without a value stop the kernel build (`syncconfig`); list them all at once with `make ARCH=mips listnewconfig` in the kernel tree and set them in the fragment. Then:

```bash
C=$(ls build_dir/target-mipsel_24kc_musl/linux-ramips_mt76x8/linux-*/.config)
grep -E '^(# )?CONFIG_(IPV6|NF_TABLES_INET|IP_MROUTE|IPV6_MROUTE)[= ]' "$C"   # IPv6 and inet tables on, multicast routing off (no IPTV)
```

If a kernel patch no longer applies after a kernel version bump, refresh it with `make target/linux/refresh` and review the result. If the image grew past `IMAGE_SIZE` (7616 KiB), the build fails in `check-size`. `build.sh` also stops when a module of the image needs a symbol that `TRIM_UNUSED_KSYMS` dropped. Regenerate the whitelist from both builds (each writes the symbols its modules need, even when the check fails) and build again:

```bash
docker/run.sh ./build.sh --ccache; docker/run.sh ./build.sh --qemu --ccache
sort -u bin/targets/ramips/mt76x8/kernel-symbols.txt bin/targets/malta/le/kernel-symbols.txt > a5v4-ksyms.txt
```

### 2.6. Run the QEMU bench and check the budget

```bash
docker/run.sh ./build.sh --qemu --ccache              # the same seed for malta/le
docker/run.sh --bench tests/qemu/bench.sh             # results in tmp/qemu-bench/results.txt
docker/run.sh --bench tests/qemu/bench.sh --official  # the official malta/le image, for comparison
```

All checks must pass (see [TODO.md](TODO.md#build-and-qemu) for those not automated yet). Then compare the sizes with the previous release ([Appendix B](#appendix-b-flash-and-ram-budget-check)) and explain any growth in the merge commit or the release notes.

### 2.7. Flash and verify on the device

Only with a full flash dump of the unit (every partition of [RESEARCH.md section 1](RESEARCH.md#1-hardware-flash-layout-and-installation)):

```bash
# on the router
sysupgrade -T /tmp/<file>-tplink_archer-c50-v4-squashfs-sysupgrade.bin   # dry run
sysupgrade    /tmp/<file>-tplink_archer-c50-v4-squashfs-sysupgrade.bin
```

Then run the checks from [Appendix C](#appendix-c-on-device-verification).

### 2.8. Update the documentation and publish

```bash
grep -rn "$OLD" README.md README.ru.md UPGRADING.md RESEARCH.md TODO.md   # version numbers, kernel version
# edit, then:
git add -A && git commit -m "docs: update to OpenWrt $NEW"
git push origin a5v4-25.12
git tag -d backup/pre-v$NEW
```

---

## 3. Major Release (e.g. 25.12 → 26.xx)

### 3.1. Do not merge the new series into `a5v4-25.12`

The stable branches and `main` of OpenWrt diverge (backports, version bumps); merging a new series into the old branch gives conflicts in hundreds of files that have nothing to do with this fork (the AX3200 build counted 1093). Upstream never merges these branches either. Instead, a new branch is created from the new release tag and the fork's commits are ported on top of it.

### 3.2. Create the branch

```bash
git fetch upstream --tags
git switch -c a5v4-26.xx v26.xx.0
```

### 3.3. Collect the commits to port

```bash
OLDBASE=v25.12.6
git log --reverse --no-merges --format='%h %an | %s' $OLDBASE..a5v4-25.12
```

### 3.4. Port this build's commits

```bash
git cherry-pick -x $(git log --reverse --no-merges --format=%h $OLDBASE..a5v4-25.12 -- . ':!LICENSE')
```

Skip the commits that the new series no longer needs (`git cherry-pick --skip`): the GCC 15.3.0 backport if the series has 15.3.0 or newer, mt76 patches already in the new mt76. `LICENSE` comes with the initial commit: merge `origin/main` once more with `--allow-unrelated-histories`, or `git checkout a5v4-25.12 -- LICENSE`.

### 3.5. Known conflict points

| File | Resolution |
|---|---|
| `README.md` | Keep ours. |
| `package/kernel/mt76/Makefile` | Upstream's version, `PKG_RELEASE` one higher. |
| `toolchain/gcc/…` | Drop the GCC backport if the new series has the version; otherwise port it again. |
| `package/kernel/linux/modules/netsupport.mk`, `feeds.conf.default` | Drop the `AUTOLOAD` of `kmod-wireguard` again; keep the `amneziawg` feed line (a newer commit for a new kernel). |
| `package/kernel/mac80211/Makefile`, `package/base-files/Makefile`, `77_wireless` | Re-apply the Wi-Fi defaults. |
| `.gitignore` | Remove the `/files` line again. |

During a cherry-pick: resolve, `git add <files>`, `git cherry-pick --continue`.

### 3.6. Re-validate every assumption of this build

A new series can change any of the underlying facts. Check each item before building:

1. **Device support:** `tplink_archer-c50-v4` still exists in `target/linux/ramips/image/mt76x8.mk` with `IMAGE_SIZE := 7616k`, the same `TPLINK_*` values and `IMAGES := sysupgrade.bin`, and the partitions of `mt7628an_tplink_8m-split-uboot.dtsi` are unchanged. OpenWrt lists 8/64 devices as not recommended; check the release notes that the series still builds images for them.
2. **Toolchain:** the default GCC version of the series. If it is 15.3.0 or newer, drop `CONFIG_TOOLCHAINOPTS` / `CONFIG_GCC_USE_VERSION_*` from the seed and the backport.
3. **Seed configuration:** run [2.4](#24-re-validate-the-seed-configuration); review renamed/removed packages, `KERNEL_*` options and the `small_flash` defaults of `config/Config-kernel.in` (`-Os`, no swap) and `config/Config-build.in` (no PIE).
4. **Kernel fragment and `TRIM_UNUSED_KSYMS`:** a new kernel version gets a new `config-<version>` of the target; check every line of the fragment ([2.5](#25-build-and-check-the-kernel-configuration)), regenerate the symbol whitelist, and check `dmesg` for `Unknown symbol` in QEMU and on the router. `target/linux/generic/hack-*/301-0[12]-…` (MIPS modules next to the kernel, without long calls) must still exist, or built-in modules become faster than loaded ones and the choice of [RESEARCH.md section 3](RESEARCH.md#3-size-of-the-kernel) has to be measured again.
5. **VPN modules:** `KernelPackage/wireguard` in `netsupport.mk` (the build drops its `AUTOLOAD`), the `amneziawg` feed in `feeds.conf.default` (pinned; its module is built outside the kernel tree, so a newer commit may need new symbols in the whitelist, [2.5](#25-build-and-check-the-kernel-configuration)), and that both modules still load when a tunnel is created, not at boot ([RESEARCH.md section 13](RESEARCH.md#13-vpn-wireguard-and-amneziawg)).
6. **MIPS16 and flags:** `CONFIG_USE_MIPS16` in `toolchain/Config.in`, the `mips16` build flag in `include/package.mk`, `CPU_TYPE:=24kc` of the subtarget.
7. **mt76:** the new `PKG_SOURCE_VERSION`; drop the `03xx` patches it contains ([2.2](#22-merge-the-new-tag)), the own mt7603 sensitivity fix once `mt7603_false_cca_check()` starts from a sensitivity of 0. Re-check the selection of [RESEARCH.md section 6](RESEARCH.md#6-wi-fi-driver-fixes-from-mt76-master) against the new master. After flashing, repeat the power save and sensitivity tests.
8. **Wi-Fi supplicant:** the `wpad-basic-mbedtls` variant (WPA2/WPA3, 802.11r/w) still exists in `package/network/services/hostapd/Makefile` and reports SAE to `hostapd -vsae`, which `77_wireless` asks, and the drivers still allow a client and access points on one radio (`num_different_channels`, interface limits in `mt7603/init.c` and `mt76x02_util.c`).
9. **Default packages:** `DEFAULT_PACKAGES` in `include/target.mk` and `target/linux/ramips/mt76x8/target.mk` — a new default package (an HTTPS client, a package manager) has to be removed in the seed again.
10. **busybox:** `ntpd` with `FEATURE_NTPD_SERVER`, no `telnetd`, the applets the seed turns off (`brctl`, `mkswap`, `swapon`, `swapoff`, `taskset`) still unused by the scripts of the image (`hwclock` stays for `/etc/init.d/system`), and an `ip` applet that netifd's WireGuard handler accepts (`wireguard-tools` still depends on `+!BUSYBOX_CONFIG_IP:ip`).
11. **travelmate, DoH:** the dependencies of travelmate (`curl`, `ca-bundle`, the TLS backend of libcurl; the seed turns off zlib, FTP and `file://` of libcurl, which pulled in `zlib`, and travelmate's calls of `curl` must still need none of them; HTTP/2 with `libnghttp2` stays on for DoH). `dhcp_backup()` of the https-dns-proxy init, which `feeds-patches/packages/0001-…` changes (drop the patch once upstream tests that the backup exists), and the options of https-dns-proxy that the defaults script sets.
12. **Wi-Fi in the flowtable:** with software offloading fw4 still puts the devices of the zones into the flowtable (`resolve_offload_devices()` in `fw4.uc`), not the ports of `br-lan`, and `/etc/hotplug.d/iface/20-firewall` still reloads the firewall on `ifup`. Otherwise a recreated Wi-Fi interface drops out of the flowtable on kernels before 6.16, and the build needs the hotplug script of openwrt-ax3200 (`20-firewall-wifi`, [RESEARCH.md section 8](RESEARCH.md#8-routing-acceleration-and-iptv)). Verify: after `wifi down; wifi up`, `nft list flowtable inet fw4 ft` still lists `br-lan`.
13. **Defaults script:** the UCI options `99-a5v4-defaults` sets (`firewall` `flow_offloading` and `drop_invalid`, `dropbear` `Interface`, the stock policies `REJECT` of the defaults and of the WAN zone, `system.ntp.enable_server`, travelmate, `https-dns-proxy` `dnsmasq_config_update`, `force_dns` and `conn_loss_time`), and the `wireless` options of `77_wireless`.
14. **Decisions taken by measurement** ([TODO.md](TODO.md#checks-and-measurements)): the profile of the programs, the hardening options, `JUMP_LABEL`, GRO and threaded NAPI. A new kernel, compiler or mt76 can change their outcome; repeat the measurement when one of them changes.
15. **Budget:** [Appendix B](#appendix-b-flash-and-ram-budget-check) against the last release of the old series.
16. **SPI flash clock:** patch 951 still applies in `spi_nor_probe()` after the dirmaps and before `mtd_device_register()`, with `nor->id` and `nor->sfdp`; `spi-mt7621` still takes the clock of a message from `spi->max_speed_hz` and divides 193.3 MHz by a whole number. After flashing, `dmesg | grep spi-nor` shows `c84017 (SFDP CRC-32 8d73ddc9): up to 65000000 Hz, 131072 bytes read the same` on the test unit.
17. **GRO and threaded NAPI:** patch 601 still applies to `register_netdevice()` (`make target/linux/refresh`) and no driver of the image turns GRO on by itself (the QEMU bench checks `eth0`, the Wi-Fi access point and client and `wg0`; on the router, the commands of [Appendix C](#appendix-c-on-device-verification)); a device section with `gro '1'` still turns it on (bench). `eth0` still has `/sys/class/net/eth0/threaded` when the init script runs (`START=11`). If netifd gets an option for threaded NAPI, use it instead of `a5v4-threaded-napi`.

### 3.7. Build, flash, verify and publish

1. Build with `docker/run.sh ./build.sh`, check the kernel configuration ([2.5](#25-build-and-check-the-kernel-configuration)), run the QEMU bench and check the budget ([Appendix B](#appendix-b-flash-and-ram-budget-check)).
2. Flash. When moving between series, a clean flash (`sysupgrade -n`) is the safe default; keep a configuration backup (`sysupgrade -b`).
3. Run the full [Appendix C](#appendix-c-on-device-verification) checklist.
4. Update `README.md` and `README.ru.md` (versions, the branch name in `git clone -b …`, any changed facts) and this document.
5. Publish the new branch: `git push -u origin a5v4-26.xx`, make it the default branch on GitHub, and check that the OpenWrt CI workflows that came with the new release branch are disabled.

---

## Appendix A: Simulating a Merge Without Touching the Working Tree

`git merge-tree` performs a merge in memory and lists the conflicted files; the branch and the working tree are not modified.

```bash
# Real merge of an upstream ref into the current branch
git merge-tree --write-tree --name-only HEAD v25.12.7

# Proxy for a future update of a similar size: replay an older upstream range in reverse.
# Conflicts appear exactly where those upstream changes overlap with the fork's changes.
git merge-tree --write-tree --name-only --merge-base=v25.12.6 HEAD v25.12.5   # size of one point release
git merge-tree --write-tree --name-only --merge-base=v25.12.6 HEAD v25.12.0   # whole series so far
```

The first output line is a tree ID; with exit code 1 the following lines are the conflicted files.

## Appendix B: Flash and RAM Budget Check

On the build host, after a build:

```bash
K=build_dir/target-mipsel_24kc_musl/linux-ramips_mt76x8
ls -l bin/targets/ramips/mt76x8/*tplink_archer-c50-v4-squashfs-sysupgrade.bin   # image (limit 7616 KiB)
ls -l $K/root.squashfs                                                          # programs
ls -l $K/*archer-c50-v4*kernel*                                                 # kernel as written to flash
$(ls staging_dir/toolchain-mipsel_24kc_gcc-*_musl/bin/mipsel-openwrt-linux-size) $K/linux-*/vmlinux   # kernel RAM: text + data + bss
find build_dir/target-mipsel_24kc_musl/root-ramips/lib/modules -name '*.ko' | wc -l                  # loadable modules
```

Free space for settings = 7616 KiB − image size. The reference numbers are in [RESEARCH.md section 5](RESEARCH.md#5-compiler-and-flags).

On the router:

```bash
df -k /overlay                                         # free space for settings
dmesg | grep -m1 'Memory:'                             # kernel code, data and reserved RAM
awk '{s += $2} END {print s / 1024 " KiB"}' /proc/modules   # loaded modules
grep -E 'MemTotal|MemAvailable' /proc/meminfo          # 5 minutes after boot, and after an hour with clients
```

## Appendix C: On-Device Verification

```bash
# Version and kernel
grep DISTRIB_DESCRIPTION /etc/openwrt_release; cat /proc/version
ls /etc/uci-defaults/                          # must be empty: all first-boot scripts succeeded
ls /proc/sys/net/ipv6 > /dev/null && echo "IPv6 in the kernel (expected)"

# Kernel and modules
dmesg | grep -i 'unknown symbol'               # must print nothing (TRIM_UNUSED_KSYMS whitelist)
dmesg | grep -iE 'mt76|eeprom'                 # no fallback to default calibration data
lsmod                                          # the Wi-Fi stack (cfg80211, mac80211, mt76, crypto); wireguard, amneziawg only with a tunnel
grep -A2 'chacha20-mips' /proc/crypto | head -3   # with a tunnel up: WireGuard uses the MIPS assembler ChaCha20

# Firewall and routing
nft list tables                                # table inet fw4
nft list flowtables                            # flowtable ft with br-lan and the WAN device
uci get firewall.@defaults[0].flow_offloading  # 1
[ -e /proc/net/ip_mr_vif ] && echo "multicast routing in the kernel (not expected: no IPTV)"
for d in eth0 phy0-ap0 phy1-ap0; do ubus call network.device status "{\"name\":\"$d\"}" | grep '"gro"'; done   # false
cat /sys/class/net/eth0/threaded                # 1: threaded NAPI (/etc/init.d/a5v4-threaded-napi)
cat /sys/module/mt76x02_lib/parameters/delay_int /sys/module/mt7603e/parameters/delay_int   # 2419230730 (0x9032880a)

# Services
ps w | grep '[n]tpd'                           # ntpd with -l (NTP server)
iwinfo | grep -E 'ESSID|Channel|Encryption'
wg show
logread | grep -iE 'error|fail' | tail -20
```

While a connection runs through the router, `conntrack` entries with the `[OFFLOAD]` flag in `/proc/net/nf_conntrack` confirm that software flow offloading is active; check it for a wired client, a Wi-Fi client after `wifi reload`, the PPPoE WAN, WireGuard and the WISP client.
