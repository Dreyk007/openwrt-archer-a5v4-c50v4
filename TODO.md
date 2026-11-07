# TODO

Open work on this fork: the plan of the first release, what has to be checked and measured,
decisions still open, patches to drop once upstream has the fix, and candidates that were looked
at but deferred. The status of what was submitted upstream is in the table at the end of
[AGENTS.md](AGENTS.md#upstream-contributions); the measurements are in [RESEARCH.md](RESEARCH.md).
Remove an item when it is done, and list the files of a change in
[UPGRADING.md](UPGRADING.md#11-this-builds-commits).

## First release

The plan decided on 2026-11-01. In this order; every step records its size cost
(image, `root.squashfs`, kernel in flash and RAM) in its commit. Done
([UPGRADING.md section 1.1](UPGRADING.md#11-this-builds-commits) lists the files):

- the build infrastructure (`build.sh`, the build container, the reference seed, the QEMU bench) and
  GCC 15.3.0;
- the trimmed kernel: `-O2`, no `ALL_KMODS`, the permanent modules built in, the approved options
  off, `TRIM_UNUSED_KSYMS` ([RESEARCH.md section 3](RESEARCH.md#3-size-of-the-kernel));
- IPv6 in the kernel and the programs, without the patches of option A (taken back on 2026-11-03,
  [RESEARCH.md section 4](RESEARCH.md#4-ipv6));
- the approved packages: LuCI in Russian, WireGuard and AmneziaWG (modules loaded with a tunnel,
  [RESEARCH.md section 13](RESEARCH.md#13-vpn-wireguard-and-amneziawg)), DoH with `https-dns-proxy` as in
  openwrt-ax3200 ([RESEARCH.md section 14](RESEARCH.md#14-encrypted-dns-doh)), travelmate,
  without apk, the HTTPS client and `urngd` ([RESEARCH.md section 2](RESEARCH.md#2-size-of-the-programs));
  IPTV (`igmpproxy`, `udpxy`) and multicast routing left out on 2026-11-06
  ([RESEARCH.md section 8](RESEARCH.md#8-routing-acceleration-and-iptv));
- 22 fixes of mt76 master and the own fix of the mt7603 dynamic sensitivity
  ([RESEARCH.md section 6](RESEARCH.md#6-wi-fi-driver-fixes-from-mt76-master));
- Wi-Fi on at the first boot: country PA, 2.4 GHz `HT20` on channel 1, 5 GHz `VHT80` on channel 36,
  WPA2 with the password `12345678` of the seed (the README must warn about it).
- the first-boot defaults (`files/etc/uci-defaults/99-a5v4-defaults`): flow offloading, the WAN zone
  and the global defaults dropping instead of rejecting (as in openwrt-ax3200: only a policy still at
  the stock `REJECT`; ping from the WAN is still answered), the NTP server.
- busybox without `brctl`, `mkswap`, `swapon`, `swapoff` and `taskset`; `build.sh` rebuilds busybox
  when the image has links of applets it no longer has.
- WPA3 (`wpad-basic-mbedtls`): 5 GHz WPA2/WPA3 mixed mode by default, 2.4 GHz WPA2; `drop_invalid`
  and SSH only on the LAN in the first-boot defaults (as in openwrt-ax3200). Seccomp stays off, PIE
  stays on (2026-11-02).
- Two profiles of the programs, `build.sh --profile hybrid|o2` (2026-11-02, [RESEARCH.md section 5](RESEARCH.md#5-compiler-and-flags)):
  `hybrid` (OpenWrt's `-Os` with MIPS16, ucode without MIPS16; the default of `build.sh`) and `o2`
  (`-O2 -pipe -mno-branch-likely -march=24kec -mtune=24kec`, no MIPS16). Both pass the QEMU bench;
  `o2` was chosen after the router test (2026-11-03): releases build with `--profile o2`. No LTO.
- The flowtable hotplug script of openwrt-ax3200 (`20-firewall-wifi`) is not needed: with software
  offloading the flowtable holds `br-lan`, not the Wi-Fi interfaces
  ([RESEARCH.md section 8](RESEARCH.md#8-routing-acceleration-and-iptv)).
- GRO off and threaded NAPI on `eth0` (decided on 2026-11-06,
  [RESEARCH.md section 12](RESEARCH.md#12-tests-on-the-router)): GRO off on every network device by
  the kernel (`target/linux/generic/hack-6.12/601-…`), threaded NAPI from
  `files/etc/init.d/a5v4-threaded-napi`; the QEMU bench checks both.

1. **The router.** A full dump of all partitions before the first flash (`radio` and `rom` are
    unique to the unit), then `sysupgrade` (`-f` with a configuration tested in QEMU keeps the
    remote access), then the checks below.
2. **Release.**
    - Documentation: `README.md` and `README.ru.md` for users, now placeholders: installation and
      backup ([RESEARCH.md section 1](RESEARCH.md#1-hardware-flash-layout-and-installation)), the
      warnings (default Wi-Fi password, country PA, A5 v6 / C50 v6 are other hardware: the label,
      no WPS LED, [RESEARCH.md section 15](RESEARCH.md#15-the-4pda-thread); TFTP needs the
      firewall of the computer off; 5 GHz
      starts in WPA2/WPA3 mode, 2.4 GHz in WPA2: a device that cannot join 5 GHz gets WPA2 there
      in LuCI; SSH only at the LAN address, also through WireGuard), what the
      build changes and leaves out ([RESEARCH.md section 10](RESEARCH.md#10-what-the-image-leaves-out)),
      flash and RAM, the packages, setting up WISP, WireGuard and AmneziaWG (remote access through
      a VPS, full tunnel); no IPTV over multicast (the ISP's own router or set-top box; a set-top
      box on its own VLAN works with the switch settings); DoH: on by default, ISP pages that rely on its DNS do not open,
      no name resolves while DoH is unreachable, and how to turn it off
      ([RESEARCH.md section 14](RESEARCH.md#14-encrypted-dns-doh)); GRO off and threaded NAPI: what
      they give, and how to turn them on or off (a device section with `gro '1'`,
      `a5v4.network.threaded_napi`); `BUILDING.md`, `BUILDING.ru.md`; the measurements in RESEARCH.md; the
      tables of UPGRADING.md.
    - `.github/workflows/build-a5v4.yml` after `build-ax3200.yml` (no `release.json` and
      fwupdate): the build in the container, `sha256sums`, attestation, tag `v25.12.6-a5v4-r1`.
    - Before the push, disable the OpenWrt CI workflows that came with the tree; make
      `a5v4-25.12` the default branch on GitHub (or fast-forward `main` to it).
    - A draft of the post for the 4pda thread (BBCode, in Russian).

## Checks and measurements

Record the setup, the numbers and the decision of each in [RESEARCH.md](RESEARCH.md).

### Build and QEMU

`tests/qemu/bench.sh` automates the checks marked *(bench)*; extend it when a step adds what it
needs (travelmate tests with the WISP step). The image
never exceeds 7616 KiB; the reference build matched the official image (RESEARCH.md, *Method and
sources*).
- **Sizes of the open decisions:** busybox applets one by one (a list with sizes is in RESEARCH.md
  section 2).
- **Kernel modules:** `build.sh` stops when the kernel does not export a symbol that a module of the
  image needs (`TRIM_UNUSED_KSYMS`); `mt7603e` and `mt76x2e` load without hardware and `dmesg` shows
  no `Unknown symbol` *(bench)*. After a change of the module set, regenerate the whitelist from
  both builds ([UPGRADING.md section 2.5](UPGRADING.md#25-build-and-check-the-kernel-configuration)).
- **WireGuard crypto:** with a tunnel up, ChaCha20 and Poly1305 are the MIPS assembler versions of
  `kmod-crypto-lib-chacha20` and `-poly1305` (`chacha20-mips` in `/proc/crypto`).
- **IPv6:** a ULA by SLAAC in the LAN and ping to the router over IPv6, `odhcp6c` on `wan6`, the
  IPv6 rules of fw4 *(bench)*; on the router (2026-11-03) the ULA in the LAN and the firewall
  rules, but its ISP offers no IPv6. Still open: IPv6 from an ISP that offers it (a user's report,
  or a DHCPv6 server with prefix delegation on the WAN side of the bench).
- **VPN modules:** `wireguard` and `amneziawg` not loaded after the boot, loaded with a tunnel;
  AmneziaWG without obfuscation against a WireGuard peer, with obfuscation between two
  AmneziaWG interfaces *(bench)*.
- **DoH:** two instances, dnsmasq asks only them, no forced DNS; turned off as the README says,
  dnsmasq asks the ISP's DNS again with no proxy address left, HTTP/2 without errors in the
  log *(bench)*. DoH answers on the router, no DNS in the clear (2026-11-03). Still open: the
  first boot of an image built weeks earlier (the clock starts at the build time, TLS
  needs a valid clock, NTP needs DNS).
- **Services:** DHCP, DNS, PPPoE against `pppoe-server`, the NTP server answers, SSH, LuCI login
  over HTTP, LuCI in Russian, a WireGuard handshake and SSH through the tunnel with netifd's
  WireGuard handler on busybox `ip` *(bench)*.
- **Flow offloading coverage:** `[OFFLOAD]` for LAN → WAN and a PPPoE WAN *(bench)*, WireGuard and
  the WISP client interface. After `wifi reload` the flowtable still holds `br-lan` and, once its
  interface is up again, the WISP client interface *(bench, by hand)*.
- **No IPTV:** no multicast routing in the kernel, and a LAN client that joins a group gets no
  multicast from the WAN *(bench)*. The checks of `igmpproxy` and `udpxy` stay in the bench for an
  image that carries them again (they need `altnet 0.0.0.0/0`, RESEARCH.md section 8).
- **travelmate on `mac80211_hwsim`:** it switches between two upstream networks; when the upstream
  disappears the local access point on the same radio stays up; it reconnects when the upstream
  comes back.
- **GRO and threaded NAPI:** no `gro` option in the configuration, GRO off on `eth0`, on the Wi-Fi
  access point and client (also after `wifi down; wifi up`) and on `wg0`, threaded NAPI on `eth0`
  with its `napi/eth0-*` thread, both again after a reboot, and a device section with `gro '1'`
  turns GRO on *(bench)*.
- **First boot:** `/etc/uci-defaults` is empty afterwards, the defaults are set *(bench)*; they apply once
  (marker; test with a sysupgrade that keeps settings); without
  `urngd` the time to `crng init done` and to the dropbear host keys stays short.

### On the router

- Before the first flash: the dump of all partitions. After it: the checks of
  [UPGRADING.md appendix C](UPGRADING.md#appendix-c-on-device-verification), both radios, all
  ports.
- **Calibration:** `dmesg` shows no fallback to default EEPROM data for either radio.
- **RAM:** `MemAvailable` 5 minutes after boot and after an hour with clients, for both profiles.
- **Profiles `hybrid` / `o2`** (`hybrid` measured on 2026-11-03, [RESEARCH.md section 12](RESEARCH.md#12-tests-on-the-router);
  the images of one commit, flashed in turn with the settings kept; `tests/router/router-bench.sh`):
  `tests/router/luci-bench.sh` a few times each, interleaved (LuCI's HTML and ubus calls on the router
  itself); the same pages in a browser; `MemAvailable` 5 minutes after boot and after an hour with
  clients; the time of a WPA3 connection; the time from power on to SSH. The forwarding path is the
  kernel's and the same in both. If `hybrid` loses on LuCI, try it with libubox, libuci, rpcd,
  uhttpd and json-c without MIPS16 too: in `o2` these stay at the `-Os` of their CMakeLists.
- **Kernel hardening:** a build without `SLAB_FREELIST_HARDENED` and the kernel stack protector
  against the normal one. The threat model is attacks from the WAN and from Wi-Fi clients that
  are not authorised. Both reach kernel code (frame parsing in mac80211/mt76, the network stack,
  PPPoE, WireGuard) and services that drop root (wpad runs as `network`, dnsmasq as `dnsmasq`), so
  the hardening stays by default. Only these two options sit on the forwarding path:
  `HARDENED_USERCOPY` only checks copies between programs and the kernel, `SLAB_FREELIST_RANDOM`
  only runs when a new slab page is set up, and the hardening of the programs does not touch
  forwarded packets. Turning the kernel hardening off saved 9 KiB of flash and 25 KiB of RAM in
  the test builds; on the AX3200 (aarch64, a partly different set) ~5 % CPU per Gbit/s in one
  direction and nothing in the other. Turn the two off only if the difference is clear.
- **`JUMP_LABEL`** (off in OpenWrt, supported on MIPS): static keys of the packet path (netfilter
  hooks, ingress/egress) become patched no-ops instead of a memory read per packet. A/B of the CPU
  load at the same throughput, the kernel size, stability over a day.
- **GRO off and threaded NAPI on the router** (the defaults since 2026-11-06,
  [RESEARCH.md section 12](RESEARCH.md#12-tests-on-the-router)): flash the image with them (the
  owner's OK), check them with the commands of
  [UPGRADING.md appendix C](UPGRADING.md#appendix-c-on-device-verification), and measure in this
  state what was not measured: the client of travelmate and a long run with the real traffic of
  the site. Then the boot with a series of reboots (the boot item below). Done on 2026-11-06: GRO
  off everywhere, WireGuard the same with GRO off on `wg0`, threaded NAPI at boot from the init
  script (the debug image `o2-dev-irq`).
- **mt76x02 reads MT7612E registers over PCIe for every frame** (2026-11-05; handed to other
  developers as tasks on 2026-11-07, the agent reviews their results): `mt76_dma_tx_cleanup`
  and `mt76_mmio_rr` take about a quarter of the CPU of a 90 Mbit/s download on 5 GHz: the DMA
  index of each TX queue on every cleanup, two words of the TX status FIFO per frame. Candidates:
  fewer reads (skip idle queues, read the status FIFO in batches or only for the frames that rate
  control samples), and the delay interrupts of `MT_WPDMA_DELAY_INT_CFG` for RX and TX in place of
  the per-frame ones (TX is configured but unused, RESEARCH.md section 12; the interrupt handler
  must then acknowledge the raw status, as openwrt/mt76 PR #1138 does); measure each with
  `labtest.sh`, then offer upstream (openwrt/mt76). The delay interrupts are in `0326` (`delay_int`
  of `mt76x02_lib`, applied at `wifi up`, off by default) and work (2026-11-06); left: their effect
  with a 5 GHz client. The phone did not come back after the restart of the radio that applies them
  (2026-11-07). Measured with a phone reconnected by hand (2026-11-07): a third fewer interrupts,
  the same throughput and CPU in UDP from the router and LAN ↔ 5 GHz (RESEARCH.md section 12); on by
  default since then, the owner's choice, to watch it in use (latency on 5 GHz, MCU timeouts or
  stalls in `logread`, the watchdog of mt76x02). The reads over PCIe in the TX cleanup remain the
  candidate for CPU.
- **Interrupt moderation of `eth0`** (2026-11-06, RESEARCH.md section 8): the `ralink` driver turns
  the delay interrupt of the frame engine off, the mainline `mtk_eth_soc` moderates it with net DIM
  on the MT7628. First, without a new image, `napi_defer_hard_irqs` and `gro_flush_timeout` of
  `eth0` (the kernel's own moderation); then a fixed delay in `FE_REG_DLY_INT_CFG`, then DIM ported
  from `mtk_eth_soc`. Measure the CPU per Mbit/s of a wired download and LAN → Wi-Fi with
  `labtest.sh`, and the latency of a ping under load. On 2026-11-06 the kernel's deferral and the
  delay interrupt (`ethtool -C`, in the driver since then) changed nothing for WireGuard at about
  2300 packets/s and cost 0.05–0.2 ms of ping (RESEARCH.md section 12). With the PC on the cable
  at 85–90 Mbit/s (2026-11-07) the delay interrupt at 200 µs saved about a fifth of the CPU per
  Mbit/s both ways (0.67 → 0.54 and 0.58 → 0.46 %/Mbit) with a third of the interrupts. On by
  default since 2026-11-07 (`FE_DLY_INT_DEFAULT` in the driver); perhaps 100 µs at the same load
  later.
- **Wi-Fi ↔ internet is bound by the CPU at about 65–75 Mbit/s** (2026-11-03, a phone on 5 GHz, a
  speed test, the download of another client paused). Near the router: −31…−43 dBm, VHT MCS 9 with
  2 streams both ways, 45–67 Mbit/s, CPU idle 13–26 %. In a far room: −70…−81 dBm, 60–66 Mbit/s,
  idle 8–20 %. The CPU takes about 1.5 % per Mbit/s of Wi-Fi traffic (idle 40–50 % at 30–35 Mbit/s
  of a download). Candidates: GRO (above), `JUMP_LABEL`; measure each with the same speed test.
  The speed test apps of the phone often ended with an error at this load; the router showed no
  drops, no invalid conntrack entries and no disconnects. Which phase fails is open.
- **2.4 GHz is slow to a phone near the router** (2026-11-03): at −28 dBm, HT MCS 12–13 (2 streams),
  a speed test got 8–10 Mbit/s with the CPU 75–80 % idle and the download paused. A device in power
  save on 2.4 GHz had 1802 failed and 17 629 retried frames for 26 KB of traffic, while a PC that
  does not doze had almost none. Suspect the power-save handling of `mt7603`: the stock driver or
  the fork's fixes of it. A/B with the test image without the fork's 23 mt76 patches (`0300`–`0322`,
  mt76 as in 25.12.6; built on 2026-11-03 on the build PC): the same phone near the router, speed,
  TX retries and failures per packet, the power-save device's counters; then bisect if they differ.
  The router sends UDP at 45 Mbit/s to a strong one-stream client on 2.4 GHz (2026-11-05), so the
  radio is not the limit: test the phone again with UDP from the router (`tests/router/udptest.sh`)
  and with TCP, awake and in power save. On 2026-11-06 the same phone at −65 dBm (MCS 15, 2
  streams, screen off) took UDP from the router at 26–37 Mbit/s with 0.01–0.04 retries per frame
  and no failed frame, and TCP through the internet at up to 45 Mbit/s down and 86 up: not
  reproduced there. By day (09:30–10:20, the phone perhaps moved and in use) it did show:
  downloads of 3–13 Mbit/s with 0.5–1.9 retries per frame and hundreds of failed frames, the CPU
  mostly idle, while at night, with the phone asleep, it was fast. The phone streams audio to
  Bluetooth headphones almost all the time (the owner): Bluetooth takes the phone's 2.4 GHz radio
  from Wi-Fi, which explains slow downloads with fast uploads, and 5 GHz fast. Left, to close it:
  a download with the headphones playing and one without, the phone at the same place (someone at
  the site). If that confirms it, the router has nothing to fix, and the A/B without the fork's
  mt76 patches is not needed.
- **mt7603 dynamic sensitivity** (the own fix; on 2026-11-05 seen moving −100…−82 dBm on a busy
  channel and back to 0, near the weakest client's RSSI − 15 dB; the A/B below is left): the debug
  image; `Sensitivity:` in
  `/sys/kernel/debug/ieee80211/phy0/mt76/radio` leaves 0 on a busy channel and never goes above the
  weakest client's RSSI − 15 dB; A/B of the channel busy time and of ping loss to the clients, as
  for the MT7622 in openwrt-ax3200. Then submit the fix to openwrt/mt76.
- **Open mt7603 changes of openwrt/mt76, taken on 2026-11-06** (`0324` PR #941, `0325` PR #1136):
  RSSI from RCPI instead of IBRssi, which swings 15–20 dB near the router with the gain of the LNA;
  the two clients read steady values (RESEARCH.md section 12). Left: the dynamic sensitivity of the
  build over a day with `dbglog.sh`, since it follows the weakest client's RSSI; PR #941 (EDCA after
  a change of the slot time) has no measurements, upstream or here.
- **mt76x2 gain control** (`ed62359`): the station RSSI average that the AGC uses is no longer the
  −75 dBm fallback.
- **Range and stability of Wi-Fi:** `iwinfo <dev> txpowerlist` and the RSSI at a distance with PA and
  with RU; 24 hours with phones in power save; long downloads and pings after idle periods on
  2.4 GHz.
- **WPA3:** the time of an SAE handshake (`logread`, a client connecting to the 5 GHz access
  point) and the CPU load while clients connect; a device with WPA2 only and a phone with WPA3 on
  the mixed 5 GHz network. On 2026-11-06 a phone moved by the router from 2.4 GHz to the 5 GHz
  network (SAE only) at −82 dBm completed SAE, the 4-way handshake and DHCP within 1–2 s, with no
  CPU to speak of. Forced moves of a phone with its screen off measure Android's scans (every
  ~3.5 min) and its blocklist after a ban, not the router: repeat `tests/router/bandswitch.sh` with
  the screen kept on.
- **The flash clock checked at boot** (patch 951, 2026-11-06, [RESEARCH.md section 12](RESEARCH.md#12-tests-on-the-router)):
  both branches checked on the router with the debug image (96.7 MHz rejected, 64.4 MHz taken,
  reads equal to those at 48.3 MHz); the release image of 2026-11-06 took 64.4 MHz as well. Left:
  its boot measured as in the boot investigation; reports of other units (JEDEC ID and SFDP CRC-32
  from `dmesg | grep spi-nor`) to learn which chips pass.
- **WISP with the second router:** throughput in both directions (in 2019 the C50 v4 as a 5 GHz
  client uploaded at 0.2–2 Mbit/s, [RESEARCH.md section 16](RESEARCH.md#16-the-openwrt-forum)); the
  upstream switched off and on (travelmate).
- **WireGuard and AmneziaWG:** throughput with the router as a client of a VPS and as a full tunnel
  for the LAN, AmneziaWG with and without obfuscation; no DNS leak in the full tunnel. WireGuard in
  states A and U done on 2026-11-06 with the router's own iperf3 (A 27.7 up / 23.1 down, U 29.8 /
  24.7 Mbit/s); AmneziaWG on a release image, since the debug image leaves it out.
- **Boot time** ([RESEARCH.md section 12](RESEARCH.md#12-tests-on-the-router)): the boot is bound by
  reading the flash, and odhcpd adds about 30 MiB of reads while the radios are set up. Candidates,
  each to be measured with the same reboots (`/proc/diskstats` of `mtdblock4`, WAN and AP times):
  - (these two also bound the CPU that memory pressure costs at run time: the page cache then re-reads
    the programs from the flash, [RESEARCH.md section 12](RESEARCH.md#12-tests-on-the-router), the
    debug image)
  - the SPI flash at 64.4 MHz (the GD25Q64 of the test unit, after a check at boot) or 48.3 MHz
    (other chips) instead of 9.67 MHz: in the device tree since 2026-11-05, by chip since
    2026-11-06 ([RESEARCH.md section 12](RESEARCH.md#12-tests-on-the-router)); the boot times of
    the release image with it are still to be measured, by the same reboots;
  - smaller squashfs blocks (`CONFIG_TARGET_SQUASHFS_BLOCK_SIZE` 256 instead of 1024 KiB): less
    read per page fault, a larger image (measure);
  - odhcpd started after the radios are up, e.g. a delayed trigger on the LAN (IPv6 in the LAN
    then comes a minute later);
  - netifd: a longer timeout of the Wi-Fi setup scripts (30 s now), so that a slow setup is not
    killed and started again (also a candidate for upstream);
  - https-dns-proxy: keep the DoH servers of dnsmasq at a shutdown, so that the next boot does not
    send DNS to the ISP until the proxies run (also a candidate for upstream);
  - why hostapd waits up to 47 s in `COUNTRY_UPDATE`.
- **The WAN MAC address override in LuCI** (2026-11-06, [RESEARCH.md section 15](RESEARCH.md#15-the-4pda-thread)):
  on 4pda it did not take effect on OpenWrt 19.07 for some users. Set it in LuCI on `wan`, check the
  address on `eth0.2` and the DHCP request of the WAN (`tcpdump` of the debug image), after a reboot too.
- **Installation from the stock firmware** (TFTP recovery, [RESEARCH.md section 1](RESEARCH.md#1-hardware-flash-layout-and-installation))
  with this build's image, when there is physical access.

## Open decisions

None at the moment (2026-11-06: IGMP snooping on `br-lan` went with IPTV).

## Space reserve

What can go when the flash runs short, measured against the packages step
([RESEARCH.md section 2](RESEARCH.md#2-size-of-the-programs)); each still needs the owner's approval
then.

- **libcurl without TLS** (`LIBCURL_NOSSL`, 2026-11-02 kept with TLS): travelmate keeps its captive
  portal check over HTTP, but cannot log in to captive portals over HTTPS. Alone −18 KiB of
  `root.squashfs`, since `wpad-basic-mbedtls` keeps `mbedtls`; together with `wpad-basic` (no
  WPA3) −265 KiB (248 + 17, measured on 2026-11-01 and 2026-11-02).
- **PIE of the network-facing daemons off** (`PKG_ASLR_PIE_NONE`, 2026-11-02 kept on): −104 KiB of
  `root.squashfs` and about 320 KB of RAM; the code of wpad, dnsmasq, pppd, dropbear, uhttpd, rpcd,
  ubus and procd then always loads at the same address
  ([RESEARCH.md section 9](RESEARCH.md#9-kernel-hardening)).
- **busybox tools for diagnostics:** `ifconfig`, `netstat`, `nslookup`, `traceroute`, `top`,
  `time`, `nc`, `less`, about 17 KiB together.

## To submit upstream

Fixes of this fork that matter beyond this router. The agent prepares each one on its own branch
from the upstream branch, the owner reviews, signs off and submits it
([AGENTS.md](AGENTS.md#upstream-contributions): real name, `Assisted-by: LLM`, the AI assistance
disclosed in the PR, OpenWrt's `check_formalities.sh` before submitting). Once one is submitted,
the table in AGENTS.md gets the link.

- **ramips: rt3050-esw: keep the WAN port disabled until it is configured** → openwrt/openwrt
  (main, then a `[25.12]` backport). The empty configuration of the switch at probe and reset
  bridges the WAN port to the LAN until userspace applies the VLANs, so a LAN client can get a
  lease from the ISP after a reboot ([RESEARCH.md section 1](RESEARCH.md#1-hardware-flash-layout-and-installation)).
  **Ready:** checked on the router on 2026-11-03 (the WAN port comes up only after preinit, no ISP
  lease on the LAN). Before submitting: compare `esw_rt3050.c` of main, and say in the PR which
  boards the change touches (those with `mediatek,portmap`).
- **https-dns-proxy: keep the backup of an empty dnsmasq server list** → openwrt/packages
  (`net/https-dns-proxy`, maintainer Stan Grishin). After stopping or disabling DoH, the proxy
  addresses stayed among the servers of dnsmasq
  ([RESEARCH.md section 14](RESEARCH.md#14-encrypted-dns-doh)). **Ready:** the package test fails
  without the fix and passes with it, and the QEMU bench and the router confirm it (2026-11-03).
  Before submitting: rebase onto master and set `PKG_RELEASE` one above master's.
- **mt7603: let the dynamic sensitivity start from 0** → openwrt/mt76. Since `f7e9be8` the
  adaptive sensitivity of the 2.4 GHz radio never starts
  ([RESEARCH.md section 6](RESEARCH.md#6-wi-fi-driver-fixes-from-mt76-master)). **Not ready:** it
  needs the test on the router with a dev build that has debugfs (`Sensitivity:` moving on a busy
  channel, A/B of the channel busy time and the ping loss) first.
- **https_dns_proxy (the program): log the missing HTTP/2 once** → aarond10/https_dns_proxy.
  With a libcurl without HTTP/2 every request logs `Setting HTTP/2 version failed`
  (`https_set_request_version()` in `src/https_client.c`; 399 lines in the first hour on the
  router). It could check `curl_version_info()` for HTTP/2 at the start, warn once and use
  HTTP/1.1. **A candidate, not prepared:** this build has HTTP/2 now
  ([RESEARCH.md section 14](RESEARCH.md#14-encrypted-dns-doh)).

- **base-files and libubox: the GRO default of `board.json`** → openwrt/openwrt and
  openwrt/libubox. `ucidef_set_network_device_gro` (`01d675687c`, 2023) writes `"gro": "0"`, a
  string, and netifd's `config_get_default_gro()` takes only a boolean, so the helper does nothing;
  and `json_load` of jshn turns a `-` in a key into `_`, so an entry for `phy0-ap0` does not
  survive a later `board.d` script (`99-default_network` always runs last). Both shown on the QEMU
  bench on 2026-11-06 ([RESEARCH.md section 12](RESEARCH.md#12-tests-on-the-router)); no board of
  the tree calls the helper. **A candidate, not prepared:** the build uses device sections
  instead. The first fix is one line (`json_add_boolean`); the second needs jshn to keep the
  original key on load.

## When upstream merges

Each patch the fork carries gets an item here: what it waits for, and when to drop it.

- **The mt7603 sensitivity fix** (`package/kernel/mt76/patches/0322-*.patch`). After the test on the router,
  submit it to openwrt/mt76 ([AGENTS.md](AGENTS.md#upstream-contributions)); drop it once the mt76
  of the build has it.
- **WAN isolation of `rt3050-esw`** (`target/linux/ramips/files/drivers/net/ethernet/ralink/esw_rt3050.c`,
  checked on the router on 2026-11-03): submit to openwrt/openwrt; drop the change once the driver of a
  release keeps the WAN port isolated until it is configured.
- **https-dns-proxy: the backup of an empty dnsmasq server list** (`feeds-patches/packages/0001-*.patch`):
  submit to openwrt/packages ([AGENTS.md](AGENTS.md#upstream-contributions)); drop it once the feed
  tests that the backup exists.
- **The open pull requests of openwrt/mt76** (`0323` #1166, `0324` #941, `0325` #1136, taken on
  2026-11-06): drop each one when mt76 has it, or adapt it to the version that is merged.
- **The 22 mt76 commits** (`0300`–`0321`): drop each one that the mt76 of a new OpenWrt release contains
  ([UPGRADING.md section 2.2](UPGRADING.md#22-merge-the-new-tag)).
- **GCC 15.3.0** (three commits of OpenWrt main, [UPGRADING.md section 1.1](UPGRADING.md#11-this-builds-commits)):
  drop them once the series builds 15.3.0 or newer by default.

## Deferred

Postponed by the owner on 2026-11-07, with PPPoE on the router (the bench covers it):

- **mt7603 hangs when the 2.4 GHz radio is reconfigured under load** (the deadlock fix `0323` is in the build) (seen on 2026-11-03, a serious
  bug): `htmode` HT20 → HT40 and `wifi up radio0` while a download with many TCP flows kept the
  channel 88 % busy. At the teardown of `phy0-ap0` the firmware did not answer `MCU message 08`
  (`MCU_EXT_CMD_CHANNEL_SWITCH`),
  hostapd stayed in `D` in `sendmsg` with `iw` and the `ipv6_addrconf` kworker behind it, the
  2.4 GHz network was gone (5 GHz and wired kept forwarding), and only a reboot brought it back.
  With the download paused the same `wifi up radio0` passed twice (HT40, HT40 with `noscan`), and
  so did the switch back HT40 → HT20 under load (26 Mbit/s): load seems needed, but does not always
  cause it. Find out how often it happens (repeated switches under load, both directions), whether
  other changes do it (channel, TX power, `wifi reload`), whether the 22 backported commits or the
  sensitivity fix play a part (an image without them), and what holds the locks: a dev build with
  `KALLSYMS` and debugfs
  (`/proc/<pid>/stack`, `echo w > /proc/sysrq-trigger`). Then a fix or a report to openwrt/mt76.
  On the debug image (2026-11-05, `tests/router/hangload.sh`): 27 switches, 15 idle and 12 under a
  UDP stream of 20–45 Mbit/s, without a hang. Left: TCP with many flows to a client and
  the release kernel. On 2026-11-06 one switch under a phone's TCP download (42 Mbit/s, 4 flows)
  passed (`tests/router/hangtcp.sh`), but the phone's iperf3 does not survive the reconnect, so
  the TCP case needs a client that keeps its flows, e.g. a PC with a torrent. **A likely cause,
  found on 2026-11-06:** when a channel switch fails (the MCU timeout of message 08),
  `mt7603_set_channel()` calls `mt7603_mac_work()` directly, which takes `dev->mutex` that
  `mt76_set_channel()` already holds: the driver deadlocks, as seen here (hostapd in `D`).
  openwrt/mt76 PR #1166 (a draft, MT7628 on a TL-MR3420 v5) queues the work instead; our mt76
  has the same code. Taken as `0323` (2026-11-06); the MCU timeout itself stays, but the watchdog
  can then recover. Repeat `hangtcp.sh` with a client that keeps its flows. The OpenWrt forum reports 2.4 GHz stopping under heavy traffic until a reboot on
  21.02 and 22.03, without a reconfiguration ([RESEARCH.md section 16](RESEARCH.md#16-the-openwrt-forum)).
- **A DFS channel on 5 GHz** (e.g. 52 or 100): the access point starts after the channel check;
  on 19.07 only 36–48 and 149–165 worked ([RESEARCH.md section 16](RESEARCH.md#16-the-openwrt-forum)).
  Channel 52 of the test router does not count: the rules of the country set on it need no radar
  check there. Set a country whose rules need one; the 5 GHz network has no clients at the site.
- **LTO.** −5 KiB without MIPS16, breaks shared libraries with it. Not worth it.
- **Firmware updates from LuCI** as in openwrt-ax3200. They need an HTTPS client, certificates
  and `mbedtls`, which this build leaves out ([RESEARCH.md section 2](RESEARCH.md#2-size-of-the-programs)).
  Not planned.
- **SQM.** Not required. If a slow link with bufferbloat needs it, measure CAKE with software flow
  offloading at 50–100 Mbit/s first.
- **zram.** The first build has no swap, like the official image: `KERNEL_SWAP` is off for
  `small_flash` targets (`config/Config-kernel.in`), so the official `zram-swap` would not even
  start on this router. zram costs the swap code of the kernel (`KERNEL_SWAP`), zram, zsmalloc and
  a compressor, in flash and RAM, plus CPU. It only helps under memory pressure: without swap the
  kernel then drops the page cache of squashfs and decompresses it from flash again.
  - Measure the kernel with `SWAP` + `ZRAM` against the one without.
  - Measure `MemAvailable` and `vmstat` (`pgmajfault`, `pswpin`) in a peak scenario (LuCI pages,
    a travelmate scan, a WireGuard tunnel, ~2000 conntrack entries, an image for sysupgrade in
    `/tmp`), in QEMU with `-m 64` and on the router.
  - Leave zram out if `MemAvailable` stays at about 16 MB or more at the peak without bursts of
    major faults; otherwise add it with the compressor that costs less CPU (lz4 or lzo-rle).
- **IPTV** (left out on 2026-11-06, [RESEARCH.md section 8](RESEARCH.md#8-routing-acceleration-and-iptv)):
  `igmpproxy`, `udpxy` with `luci-app-udpxy` and the multicast routing of the kernel come back if
  users ask for them; they cost 64 KiB of the image (41 KiB of `root.squashfs`, 16 KiB of
  the kernel in flash) and 55 KiB of kernel RAM. The bench still has their checks.
- **Beamforming on the MT7612E.** The chip supports it, the mt76x2 driver does not implement it.
  A project of its own without documentation; not planned.

## Next releases

- **25.12.7 (Linux 6.12.113).** Merge the tag ([UPGRADING.md section 2](UPGRADING.md#2-minor-release-eg-25126--25127)).
  This build does not use the official kmods, so the kernel version does not have to match a
  release; still, merge release tags, and cherry-pick single fixes of `openwrt-25.12` in between.
  Check the mt76 patches against the new release and the size budget.
