![OpenWrt logo](include/logo.png)

### English · [Русский](README.ru.md)

# OpenWrt 25.12.6 — Optimized Custom Build for TP-Link Archer A5 v4 / Archer C50 v4

[![Download the latest release](https://img.shields.io/github/v/release/Dreyk007/openwrt-archer-a5v4-c50v4?style=for-the-badge&label=Download&color=2ea44f)](https://github.com/Dreyk007/openwrt-archer-a5v4-c50v4/releases/latest) [![Installation](https://img.shields.io/badge/Installation-0969da?style=for-the-badge)](#installation)

> [!NOTE]
> The first release is being prepared. Until it is published, the download links on this page do not work.

**Which file to download:** there is one firmware file,
`openwrt-ramips-mt76x8-tplink_archer-c50-v4-squashfs-sysupgrade.bin`.
* **From OpenWrt** it is installed as it is.
* **From the stock firmware** it goes through the recovery file `tp_recovery.bin` ([Installation](#installation)).

This repository (branch **`a5v4-25.12`**) is a fork of the stable **OpenWrt 25.12.6** release (`Linux 6.12.112`) for the **TP-Link
Archer A5 v4** (also v4.2 and v4.20) **and Archer C50 v4**, one device with one firmware:
* **MediaTek MT7628AN:** one MIPS 24KEc core at 575 MHz, with the 2.4 GHz Wi-Fi;
* **MT7612E** for 5 GHz;
* **8 MiB of flash and 64 MiB of RAM**, and 100 Mbit/s Ethernet ports.

**The goal of the build** is to get the most out of this hardware and to keep it secure:
* **faster and more reliable:** faster Wi-Fi and a faster boot, fewer Wi-Fi faults;
* **more secure:** only firmware updates fix vulnerabilities. This build is current OpenWrt with security fixes that its releases
  do not have yet, and new releases install from LuCI with one button. The stock firmware gets no such fixes;
* **a complete home router out of the box:** LuCI in Russian and English, encrypted DNS, WireGuard and AmneziaWG, internet over
  another Wi-Fi network, PPPoE and L2TP, all in 8 MiB of flash.

**The image has no package manager:** everything the router does is built in ([What the build leaves out](#what-the-build-leaves-out)).

> [!WARNING]
> Wi-Fi is **on at the first boot with the public password `12345678`**, and the web interface has **no root password**. Set both
> right after the installation (LuCI → *System → Administration* and *Network → Wireless*).

> [!CAUTION]
> **The v4 only.** The Archer A5 v6 / C50 v6 is other hardware (5 GHz on an MT7613) and takes only the images of the C50 v6. To
> tell them apart:
> * the label on the bottom of the router shows the hardware version (*Ver*);
> * the v6 has no WPS LED.

**Contents:** [Highlights](#highlights) · [Installation](#installation) · [Key changes](#key-changes) ·
[What the build leaves out](#what-the-build-leaves-out) · [Flash and RAM](#flash-and-ram) · [Firmware updates](#firmware-updates) · [Setting up](#setting-up) ·
[Pre-installed packages](#pre-installed-packages) · [Building](BUILDING.md) ·
[Research and measurements](RESEARCH.md)

---

## Highlights
* **More from the single CPU core.** The 575 MHz core is what limits Wi-Fi on this router, and the build spends less of it per
  packet ([section 4](#4-wi-fi), [section 5](#5-network-stack)).
  * A client on 5 GHz exchanged 87–95 Mbit/s with a wired computer, the limit of the 100 Mbit/s ports.
  * During those transfers the router's own programs got the CPU within a millisecond.
  * Where the CPU is the limit, 5 GHz carried up to 10 % more: UDP from the router to a client while the 2.4 GHz radio was busy.
* **Fewer Wi-Fi faults** ([section 4](#4-wi-fi)):
  * 22 driver fixes from the development of mt76, the Wi-Fi driver. They cover clients in power save, a kernel panic when a radio
    recovers, and a stalled 5 GHz queue;
  * three more fixes, among them one for a hang of the 2.4 GHz radio after a failed channel switch;
  * the adaptive sensitivity of the 2.4 GHz radio works again.
* **A faster boot:** the flash is read at 48 or 64 MHz instead of 10 MHz. In the tests the internet was up 69 s earlier, and both
  Wi-Fi networks 100–140 s earlier ([section 3](#3-flash-and-boot)).
* **Encrypted DNS by default** (DoH to Cloudflare and Google) ([Encrypted DNS](#encrypted-dns-doh)).
* **VPN:** WireGuard, and AmneziaWG where the ISP blocks WireGuard. Use them for remote access through a VPS, or for all traffic.
  Until a tunnel exists, the VPN modules are not loaded and take no memory ([VPN](#vpn-wireguard-and-amneziawg)).
* **The option to get the internet over another Wi-Fi network** (a hotel, a neighbour's router, a phone's hotspot) with
  travelmate. Off by default ([Internet over Wi-Fi](#internet-over-wi-fi-wisp)).
* **The internet connection:** DHCP, PPPoE, L2TP and IPv6 are built in ([Internet connection](#internet-connection)).
* **Safer defaults** ([section 6](#6-firewall-and-services), [section 7](#7-fixes-ahead-of-openwrt-25127)):
  * WPA2/WPA3 on 5 GHz;
  * a firewall that gives no answer on closed ports;
  * SSH only in the LAN;
  * security fixes ahead of OpenWrt 25.12.7.
* **No LAN traffic leaks through the WAN port while the router boots.** OpenWrt has this fault on this switch
  ([section 5](#5-network-stack)).
* **Recovery after an ISP outage:** when the link on the WAN port comes back, the router asks for a new address within 15 s
  ([Internet connection](#internet-connection)).
* **Your settings survive updates:** the defaults of the build are applied once per configuration
  ([section 8](#8-how-the-defaults-are-applied)).
* **Updates from LuCI:** the router finds new releases of this build on GitHub, shows a notice on the Overview page and
  installs a release with one button, keeping the settings ([Firmware updates](#firmware-updates)).

---

## Installation

> [!IMPORTANT]
> First read the [OpenWrt wiki page of the Archer C50](https://openwrt.org/toh/tp-link/archer-c50): it covers the installation,
> the recovery and the known problems of these routers. Flashing third-party firmware is at your own risk.

**Before you start:**
* **Never upload this firmware in the TP-Link web interface.** The stock firmware accepts it, and the router then reboots in a loop
  with blinking LEDs. From the stock firmware the installation goes through the TFTP recovery of the bootloader
  ([section A](#a-from-the-stock-firmware-tftp-recovery)).
* **The first boot takes about 3 minutes** until both Wi-Fi networks are up. Do not power the router off meanwhile.

### A. From the Stock Firmware (TFTP Recovery)
At power-on, the bootloader of the router can load a firmware from a computer over the network (TFTP), from a file named
`tp_recovery.bin`.

1. **Get `tp_recovery.bin`** in one of two ways:
   * **A ready file with OpenWrt 19.07:** download
     [OpenWRT - Archer A5 v4 (C-50).zip](https://4pda.to/forum/dl/post/18975128/OpenWRT+-+Archer+A5+v4+%28C-50%29.zip) from 4pda
     and unpack `tp_recovery.bin` from it into a folder of its own. This build is installed from OpenWrt 19.07 later (step 6).
   * **Your own file with this build's image**, by the
     [OpenWrt wiki](https://openwrt.org/toh/tp-link/archer-c50#installation_using_the_tftp_method) (the "v4 and v5 instructions"
     tab): the method of the
     [commit](https://github.com/openwrt/openwrt/commit/01dcd574a24864c10a9c4df4304a3ce0da5c11a9) that added this router to
     OpenWrt. A badly made file can brick the router.

     <details>
     <summary>How to make the file</summary>

     1. Download the stock firmware of your model (Archer A5 v4 or Archer C50 v4) from TP-Link's site, unpack it and rename its
        `.bin` file to `tpl.bin`.
     2. Put this build's `openwrt-ramips-mt76x8-tplink_archer-c50-v4-squashfs-sysupgrade.bin` next to it as `owrt.bin`.
     3. Run in that folder (Linux, macOS; on Windows in Git Bash or WSL):
        ```sh
        dd if=/dev/zero of=tp_recovery.bin bs=196608 count=1
        dd if=tpl.bin of=tmp.bin bs=131584 count=1
        dd if=tmp.bin of=boot.bin bs=512 skip=1
        cat boot.bin >> tp_recovery.bin
        cat owrt.bin >> tp_recovery.bin
        ```

     </details>

2. **Set up the computer.**
   * Connect it to a LAN port of the router with a cable.
   * Give that network adapter the static address `192.168.0.66` with the netmask `255.255.255.0`.
   * Turn off the computer's firewall for the time of the installation: with it on, the router often does not get the file.
3. **Start a TFTP server** for the folder with `tp_recovery.bin`:
   * **Windows:** [Tftpd64](https://pjo2.github.io/tftpd64/). Choose the folder as *Current Directory* and `192.168.0.66` in
     *Server interfaces*; its log shows the transfer.
   * **Linux:** dnsmasq:
     ```sh
     sudo dnsmasq -i <interface> -p 0 -d -z --enable-tftp --tftp-root <folder>
     ```
4. **Power the router off, hold the reset button and power the router on.** Keep holding the button until the WPS LED lights (about
   8–10 seconds), then release it. The router loads the file and writes it.
5. **Wait.** Do not power the router off for at least 3 minutes, or until three or more LEDs light: an interrupted write can brick
   the router. The router then boots the firmware of the file.
6. **Finish.**
   * Set the network adapter back to automatic (DHCP).
   * **With the ready file:** open `http://192.168.1.1`, the LuCI of OpenWrt 19.07, and install this build from it as in
     [section B](#b-from-openwrt).
   * **With your own file** the router already runs this build: open `http://192.168.1.1` (user `root`, no password), and set a
     root password and the Wi-Fi password.

### B. From OpenWrt
From any OpenWrt version, official or another build, **without keeping the settings**: the settings of another firmware do not fit
this one. An upgrade from 19.07 with the settings kept has left routers without Wi-Fi.

**In LuCI:**
1. Download `openwrt-ramips-mt76x8-tplink_archer-c50-v4-squashfs-sysupgrade.bin` to your computer from the
   [latest release](https://github.com/Dreyk007/openwrt-archer-a5v4-c50v4/releases/latest).
2. In LuCI open *System → Backup / Flash Firmware*, click *Flash image...* under *Flash new firmware image*, choose the file and
   click *Upload*.
3. **Uncheck** *Keep settings and retain the current configuration* and click *Continue*. The router writes the image and reboots,
   which takes a few minutes; do not power it off meanwhile.
4. Open `http://192.168.1.1` (user `root`, no password), and set a root password and the Wi-Fi password.

**Over SSH:**
1. **Connect to the router:** `ssh root@192.168.1.1` (built into Linux, macOS and Windows 10/11), or
   [PuTTY](https://www.chiark.greenend.org.uk/~sgtatham/putty/) on Windows with host `192.168.1.1` and user `root`.
   * The password is the root password of this router; right after an installation of OpenWrt there is none.
   * Paste one block of commands at a time. If the last line stays at the prompt after pasting, press Enter.
2. **Download the image on the router and check it** (the last command must print `OK`). Official OpenWrt has no `curl`, and its
   `wget` currently cannot download from GitHub. Install `curl` first: `apk update && apk add curl` on OpenWrt 25.12, or
   `opkg update && opkg install curl` on older versions.
   ```sh
   cd /tmp
   F=openwrt-ramips-mt76x8-tplink_archer-c50-v4-squashfs-sysupgrade.bin
   curl -fLo $F https://github.com/Dreyk007/openwrt-archer-a5v4-c50v4/releases/latest/download/$F
   curl -fsSL https://github.com/Dreyk007/openwrt-archer-a5v4-c50v4/releases/latest/download/sha256sums | grep -- $F | sha256sum -c -
   ```
   If the router has no internet, copy the file from your computer instead: `scp -O <file> root@192.168.1.1:/tmp/`. `scp` is built
   into Linux, macOS and Windows 10/11; the `-O` option is needed because OpenWrt has no SFTP server.
3. **Flash it without keeping the settings:**
   ```sh
   sysupgrade -n /tmp/openwrt-ramips-mt76x8-tplink_archer-c50-v4-squashfs-sysupgrade.bin
   ```

Images from before 2021 name the router `tplink,c50-v4`; this image accepts that name too.

### C. Updating This Build
The settings are kept. The easiest way is the update page of the build: LuCI → *System → Archer A5 v4 / C50 v4 build updates*
([Firmware updates](#firmware-updates)). The router finds a new release by itself, and the Overview page then shows a notice.

By hand, as from any OpenWrt:
1. Download the new `…-squashfs-sysupgrade.bin` to your computer from the
   [latest release](https://github.com/Dreyk007/openwrt-archer-a5v4-c50v4/releases/latest).
2. In LuCI: *System → Backup / Flash Firmware* → *Flash image...* → choose the file → *Upload*.
3. Leave *Keep settings and retain the current configuration* checked and click *Continue*.

Over SSH: connect, download and check the file as in [section B](#b-from-openwrt), then run
`sysupgrade /tmp/openwrt-ramips-mt76x8-tplink_archer-c50-v4-squashfs-sysupgrade.bin` (without `-n`).

### Back to the Stock Firmware
Use the TFTP recovery of [section A](#a-from-the-stock-firmware-tftp-recovery) with a recovery file made from the stock firmware:
the [OpenWrt wiki](https://openwrt.org/toh/tp-link/archer-c50#tftp_recovery_de-bricking) describes how. All settings are lost.

### Backup and Recovery
<details>
<summary>A copy of the factory partitions (optional)</summary>

The `radio` partition holds the Wi-Fi calibration of your unit and `rom` its MAC address; a copy from another unit does not
replace them. OpenWrt never writes these partitions, so the copy only matters if the router ever has to be restored with a flash
programmer. Log in over SSH ([how to connect](#b-from-openwrt)) and copy the partitions to `/tmp/backup`:
```sh
mkdir -p /tmp/backup
for p in factory-uboot boot config rom romfile radio; do
  cat /dev/$(grep "\"$p\"" /proc/mtd | cut -d: -f1) > /tmp/backup/$p.bin
done
ls -l /tmp/backup
```
Then copy them to your computer with `scp -O -r root@192.168.1.1:/tmp/backup .`, and keep them safe.
* The files are 192, 128 and 4 × 64 KiB.
* The firmware partition is not in the copy: it holds OpenWrt itself, which any image replaces.
* The stock firmware cannot make this copy: there, only a flash programmer reads the flash.

</details>

**When the router does not boot:**
* The TFTP recovery of [section A](#a-from-the-stock-firmware-tftp-recovery) runs from the bootloader. It brings the router back
  in most cases.
* **UART** is next to the Ethernet ports: 115200 8N1, 3.3 V. Hold `4` at power-on to stop in the console of U-Boot.
* **A flash programmer** (CH341A with a clip) writes a full copy back. A copy from another unit brings that unit's MAC addresses
  and Wi-Fi calibration.

---

## Key Changes

The measurements behind the changes are in [RESEARCH.md](RESEARCH.md).

### 1. Compiler and Programs
* **GCC 15.3.0** instead of OpenWrt's 14.3.0: smaller code.
* **The programs are built with `-O2` for the MIPS 24KEc and without MIPS16**, instead of OpenWrt's `-Os` with MIPS16.
  * Measured on the router: the shell 18–21 % faster, `gzip` 22–24 %, `sha256sum` 60 %, the WireGuard key generation 28 %.
  * LuCI pages are 1–9 % faster, and the boot reached the LAN 11 s earlier.
  * It costs 256 KiB of flash and 1–3.5 MB of RAM.

  Details: [RESEARCH.md](RESEARCH.md#5-compiler-and-flags).
* **The kernel is built with `-O2`** instead of `-Os`, OpenWrt's choice for routers with little flash: it does the routing, NAT
  and Wi-Fi.

### 2. A Smaller Kernel
* **Only what this router uses.**
  * The modules the router always loads are built in.
  * Unused functions are left out: USB, debugfs, BPF, magic SysRq, multipath routing, seccomp.
  * The kernel exports only the symbols its modules use.
* **The result:** even with `-O2` the kernel takes 6432 KiB of RAM instead of the official 7063 KiB, and 1920 KiB of flash instead of
  2075 KiB.
* **The price:** kernel modules of the official repository do not load, and a new module needs a new firmware.

Details: [RESEARCH.md](RESEARCH.md#3-size-of-the-kernel).

### 3. Flash and Boot
* **The flash is read at 48.3 MHz instead of 10 MHz.**
  * A chip that passes a read check at every boot runs at 64.4 MHz: three reads of the bootloader at both clocks must be equal.
  * Units of the v4 carry flash chips of GigaDevice, Winbond or cFeon. A GigaDevice chip passed it. 48.3 MHz is within the
    specification of all of them.
* **The effect** (a test image, the first boot after an update):
  * the internet was up 85 s after the start instead of 154 s;
  * the 2.4 GHz network at 139 s instead of 239 s, the 5 GHz one at 194 s instead of 336 s.

  Programs that the router has to read again from the flash when memory runs short, LuCI among them, wait less too.
* **Your chip:** the kernel log names the flash chip and its clock: `dmesg | grep spi-nor`.

Details: [RESEARCH.md](RESEARCH.md#12-tests-on-the-router), [the chips](RESEARCH.md#15-the-4pda-thread).

### 4. Wi-Fi
* **Defaults**, applied at the first boot and only to a radio without a password:
  * **country `PA` for both radios.** Set your own country if local rules require it: LuCI → *Network → Wireless* → *Edit* →
    *Advanced Settings* → *Country Code*. The radios transmit at 22 dBm, the maximum of their chips;
  * **2.4 GHz:** channel 1, 20 MHz, WPA2;
  * **5 GHz:** channel 36, 80 MHz. The channel has no radar detection, so the network starts at once and never has to move;
  * **WPA2/WPA3 mixed mode on 5 GHz:** devices with WPA3 use it, the others WPA2. If a device still cannot join, set *Encryption*
    to WPA2-PSK in LuCI (*Network → Wireless* → *Edit* → *Wireless Security*);
  * **network names** `archer-c50-v4-2g-0xxxx` and `archer-c50-v4-5g-1xxxx`, where `xxxx` is the end of the router's MAC address,
    and the password **`12345678`**.
* **Driver fixes** (mt76, the Wi-Fi driver of both radios):
  * **22 fixes from its development:**
    * clients in power save, whose traffic stalled until they woke up;
    * a kernel panic when the 5 GHz radio recovers, and broadcasts lost after it;
    * a 5 GHz queue that stopped under load;
    * the signal strength of the clients, which the 5 GHz receiver uses to set its gain.
  * **Three more fixes:**
    * a hang of the 2.4 GHz radio after a failed channel switch;
    * the queue parameters of 2.4 GHz after a change of the slot time;
    * a more precise signal strength of 2.4 GHz clients.
  * **An own fix:** the adaptive sensitivity of the 2.4 GHz radio, off since 2020 through a bug, works again. On a busy channel it
    moved between −100 and −82 dBm, and stayed near the signal of the weakest client minus 15 dB.

  Details: [RESEARCH.md](RESEARCH.md#6-wi-fi-driver-fixes-from-mt76-master).
* **Fewer reads of the 5 GHz chip.** Each read of one of its registers over PCIe costs 1.35 µs of waiting CPU. The driver now skips
  the reads it does not need: those of idle queues, and status polls when no status is due.
  * UDP from the router to a client: +6.5 % and +4 % for the two parts, and +10 % with the 2.4 GHz radio busy at the same time.
  * A 24-hour run and 8 channel switches showed no faults.
  * To turn it off until a reboot: `echo 0 > /sys/module/mt76x02_lib/parameters/tx_opt`. For good, add
    `options mt76x02-lib tx_opt=0` to `/etc/modules.conf` and reboot.
* **Interrupt moderation of both radios:** a radio raises one interrupt per several frames, or after at most 1 ms.
  * On 5 GHz this means a third to two fifths fewer interrupts. No difference in throughput or CPU was measured.
  * It adds up to 0.2 ms of latency when traffic is sparse.
  * To turn it off, add `options mt76x02-lib delay_int=0` (5 GHz) and `options mt7603e delay_int=0` (2.4 GHz) to
    `/etc/modules.conf` and reboot.
* **Tips:**
  * **40 MHz on 2.4 GHz** gave no more speed among the neighbouring networks, and takes their air: 20 MHz stays.
  * **Automatic channel selection (`auto`):** fixed channels stay the default (channel 1 on 2.4 GHz, channel 36 on 5 GHz, instant startup). If you choose `auto` in LuCI (*Network → Wireless* → *Edit* → *General Setup*), the build pre-configures faster presets instead of hostapd's ~27 s default scan: **~12 s on 2.4 GHz** (channels 1–11, 2 passes, preferring channels 1, 6 and 11) and **~8 s on 5 GHz** (1 pass, excluding DFS channels and channels limited below 15 dBm such as EU channels 149–165 at 25 mW). Two checkboxes appear when *Channel* is set to `auto`:
    * *2.4 GHz:* **Include channels 12 and 13 in automatic channel selection** (off by default, so devices configured for the US still see the network);
    * *5 GHz:* **Include DFS channels in automatic channel selection** (off by default, skipping 1–10 min radar checks and radar-forced channel switches; where every 5 GHz channel needs a radar check, automatic selection works only with this box on).
  * **Channels 52–64** have no radar detection under `PA`. Under the rules of most European countries they need a 1-minute check
    at every start, and a switch when a radar shows up.

### 5. Network Stack
* **Software flow offloading** is on: established connections skip most of the firewall. The MT7628 has no hardware NAT, so this
  is the fast path. Without it the same traffic took 1.3–1.8 times the CPU, and a client's upload over 5 GHz fell from about 90 to
  70 Mbit/s.
* **GRO off on every interface.** These network chips compute no checksums when they send, so every merged packet is checksummed
  again by the CPU: on this CPU GRO costs more than it saves. OpenWrt has it on.
* **Threaded NAPI on the Ethernet port.** The receive work of the port runs in a kernel thread, which the CPU shares with the
  programs.
* **Measured** against OpenWrt's defaults:
  * a client uploading to a wired computer over 5 GHz got 10 % more, at 10 % less CPU per Mbit/s;
  * WireGuard got 7–8 % more;
  * while a wired computer sent to Wi-Fi at full speed, the router's own programs (Wi-Fi, DNS, LuCI) waited 0–1 ms for the CPU,
    instead of up to a second.

  To turn GRO back on for a device (`eth0` here; `phy0-ap0` and `phy1-ap0` are the 2.4 and 5 GHz networks):
  ```sh
  uci add network device
  uci set network.@device[-1].name='eth0'
  uci set network.@device[-1].gro='1'
  uci commit network
  reboot
  ```
  To turn threaded NAPI off:
  ```sh
  uci set a5v4.network=network
  uci set a5v4.network.threaded_napi='0'
  uci commit a5v4
  reboot
  ```
* **Interrupt moderation of the Ethernet port:** at the same speed it takes a fifth less CPU per Mbit/s on the cable, with a third
  of the interrupts. The price is 0.2 ms of latency: a ping to the ISP's gateway was 3.22 instead of 3.03 ms at best.
* **No LAN traffic through the WAN port while the router boots.**
  * Until the kernel had set up the switch, all its ports formed one network. A device on the LAN could then get an address from
    the ISP's network: this was seen in the tests, and the OpenWrt wiki lists it.
  * The WAN port now stays off until its network is set up.
* **One core:** packet steering and `irqbalance` have nothing to spread the load to.

Details: [RESEARCH.md](RESEARCH.md#8-routing-acceleration-and-iptv), [the tests](RESEARCH.md#12-tests-on-the-router).

### 6. Firewall and Services
* **The WAN zone, and interfaces in no zone, drop what they do not accept** instead of rejecting it: closed ports give no answer.
  * Ping from the internet is still answered (OpenWrt's rule), so that the ISP and you can check the line.
  * Packets that connection tracking marks invalid are dropped. Without this, some of them left through the WAN with their LAN
    address.
* **SSH listens only on the LAN addresses.** Through a VPN tunnel the router is at `192.168.1.1` too.
* **An NTP server for the LAN** is on.
* **The hardening of OpenWrt stays:** the stack protector, the bounds checks, and randomised addresses of the network services.

Details: [RESEARCH.md](RESEARCH.md#9-kernel-hardening).

### 7. Fixes Ahead of OpenWrt 25.12.7
* **The web server of LuCI** (uhttpd): two security advisories. Requests were parsed past the bytes received, and one address
  could take all the slots of the web interface.
* **libubox:** a read beyond a buffer in its JSON code.
* **musl, CVE-2026-107891:** integer overflows in regular expressions.
* **The root certificate "emSign ECC Root CA – G3"** is no longer trusted: it issued certificates with keys anyone can recover.
* **dnsmasq:** large hosts files load in seconds instead of minutes.
* **Linux kernel, CVE-2026-98432:** a TCP connection to the router with crafted IPv4 options could corrupt kernel memory. This needs
  two CPU cores, so on this router it is practically unreachable; the fix is two lines.
* **No kernel panic when a packet comes back in a state the kernel does not expect** (reported with zapret and with L2TP): the
  packet is dropped, and the kernel log shows a warning once.

### 8. How the Defaults Are Applied
* **Once per configuration.**
  * The first-boot scripts run after every flash, also after an update that keeps the settings.
  * The defaults of the build (sections 5 and 6, encrypted DNS) are applied once per configuration, and a marker in
    `/etc/config/a5v4` records them. Your own changes therefore survive updates.
* **The Wi-Fi defaults** apply only to a radio without a password.
* **To apply the defaults of the build again:**
  ```sh
  uci -q delete a5v4.defaults && uci commit a5v4
  sh /rom/etc/uci-defaults/99-a5v4-defaults
  reboot
  ```

---

## What the Build Leaves Out

Against the official image of OpenWrt 25.12.6 for this router:

| Left out | What it means |
|---|---|
| **The package manager** (`apk`) and *System → Software* | Nothing can be installed or removed on the router. A change of the set is a new firmware |
| Compatibility with the official kernel modules | They do not load (the kernel is built differently) |
| LuCI over HTTPS | LuCI over HTTP in the LAN; for remote access, use a VPN ([VPN](#vpn-wireguard-and-amneziawg)) |
| Attended Sysupgrade, OpenWrt's online update | It would install plain OpenWrt; this build updates itself from LuCI ([Firmware updates](#firmware-updates)) |
| `wget` | `curl` instead |
| Multicast IPTV through the router: `igmpproxy`, `udpxy`, multicast routing | A set-top box on its own VLAN, IPTV apps and multicast inside the LAN still work |
| SQM (traffic shaping against bufferbloat) | Latency can grow while the link is fully loaded |
| zram (swap in RAM) | Memory never ran short in the tests |
| The full `ip` of iproute2 | busybox `ip` |
| USB, magic SysRq, debugfs, BPF, multipath routing, seccomp | The board has no USB port, and nothing in the image uses the rest |

Details: [RESEARCH.md](RESEARCH.md#10-what-the-image-leaves-out).

---

## Flash and RAM
* **Flash, 8 MiB:** the bootloaders and the factory data, and 7616 KiB for the firmware.
  * The image takes 6401 KiB, which leaves **1215 KiB for the settings**.
  * The official image of 25.12.6 takes 5952 KiB and leaves 1664 KiB, but packages installed later also have to fit there.
* **RAM, 64 MiB:** after the kernel, 58.6 MB are left for the system.
  * At idle 16–20 MB are available.
  * In a peak test (a 6 MB file in `/tmp`, 2000 DNS lookups and LuCI at once) the available memory never went below 11 MB.
  * OpenWrt also keeps 8 MB free for the network, beyond what it shows as available.
* **`/tmp` is RAM.** An image uploaded for an update takes 6.4 MB there until the reboot. The update page of the build checks the
  available memory itself.

---

## Firmware Updates

The router looks for new releases of this build on GitHub a few minutes after it starts and then once a day. On the update page
the check can run once a week or a month instead, or be turned off. When a release is out, the Overview page shows a notice with
its changes. LuCI → *System → Archer A5 v4 / C50 v4 build updates* lists the changes of every release since the installed one
and installs the update with one button, with or without the settings.
* **Before installing,** the router checks that the file is complete (size and SHA256) and that it fits this router, as
  *Backup / Flash Firmware* does.
* **What an update keeps:** with *Keep settings*, the settings, as *Backup / Flash Firmware* does. The build has no package
  manager, so everything else comes with the new firmware.
* **Memory:** the downloaded firmware (6.4 MB) waits in the RAM of the router until it is installed. Before the download the
  router frees the memory that cached files take (LuCI then answers more slowly for a few seconds), and it downloads only when it
  has the firmware and 6 MB more available. Otherwise the page says how much is available and needed: restart the router and try
  again, or install the update by hand ([section C](#c-updating-this-build)). *Cancel* in the last dialog frees the memory again.

The Overview page shows the release in the firmware version, e.g. *OpenWrt 25.12.6 r33311-981c978eff a5v4-r1*: name it when
you report a problem.

A firmware built by yourself has no release number: its update page shows the latest release without telling whether it is
newer.

---

## Setting Up

### Internet Connection
* **DHCP** is the default: nothing to do.
* **PPPoE:** LuCI → *Network → Interfaces* → `wan` → *Edit*.
  1. Set *Protocol* to PPPoE and click *Switch protocol*.
  2. Enter the user name and the password of the ISP.
  3. Click *Save*, then *Save & Apply*.
* **L2TP:** some ISPs run L2TP over their DHCP network. Keep `wan` at DHCP and add the tunnel:
  1. *Network → Interfaces* → *Add new interface...*: name `l2tp`, protocol L2TP → *Create interface*.
  2. Enter the *L2TP Server* given by the ISP, the *PAP/CHAP username* and the *PAP/CHAP password*.
  3. *Firewall Settings*: the zone `wan`. Click *Save*, then *Save & Apply*.

  The L2TP programs start only while such an interface exists. It was checked against a test server; reports with real ISPs are
  welcome.
* **IPv6:** if the ISP offers it, the router gets it on `wan6` and hands it on to the LAN. The LAN has local IPv6 addresses either
  way. This was tested in emulation.
* **The MAC address of the WAN**, for ISPs that bind a contract to one: *Network → Interfaces* → *Devices* → `eth0.2` →
  *Configure…* → *MAC address*.
* **After an ISP outage:** the router checks the link on the WAN port every 15 s and, when it comes back, restarts the WAN
  connection to get a new address right away.\
  If needed, this behaviour can be turned off like this:
  ```sh
  uci set a5v4.network=network
  uci set a5v4.network.wan_watch='0'
  uci commit a5v4
  /etc/init.d/a5v4-wan-watch reload
  ```

### Internet over Wi-Fi (WISP)
travelmate connects the router to another Wi-Fi network as its internet: a hotel, a neighbour's router or a phone's hotspot.
* **Setting it up:**
  1. LuCI → *Services → Travelmate*: run the *Interface Wizard* once. It creates the uplink interface in the WAN zone and turns
     travelmate on.
  2. *Wireless Stations*: scan on one radio, choose a network, enter its password and save it.
* **How it works:**
  * travelmate connects to the first available of the saved networks, and moves to another when it is lost.
  * It also handles the login pages of hotels (captive portals).
* **Tips:**
  * **Receive on one band and share on the other.** On one radio every packet goes over the air twice, which halves the speed.
  * **While the router looks for a lost network,** the access points of that radio pause.

### VPN: WireGuard and AmneziaWG
* **The protocols:** both WireGuard and AmneziaWG are built in.
* **Their kernel modules load only while a tunnel exists.**

**Setting up a tunnel from a configuration file** (the `.conf` file of a VPN provider, or of your own server):
1. LuCI → *Network → Interfaces* → *Add new interface...*: a name such as `vpn`, and the protocol *WireGuard VPN* or
   *AmneziaWG VPN* → *Create interface*.
2. *Import configuration* → *Load configuration…*, and choose the file. The keys, the address, the peer and the obfuscation
   settings are filled in.
3. Choose what goes through the tunnel:
   * **All traffic:** in the peer, *Allowed IPs* `0.0.0.0/0` (and `::/0`) with *Route Allowed IPs* on, and the firewall zone `wan`.
     The route to the VPN server itself stays on the internet connection.
   * **Only remote access to the router:** *Allowed IPs* only the network of the tunnel, and the firewall zone `lan`.
4. Click *Save*, then *Save & Apply*.

More: [WireGuard on the OpenWrt wiki](https://openwrt.org/docs/guide-user/services/vpn/wireguard/start).

**Speed:** the router's own traffic through a VPN server 85 ms away reached about 31 Mbit/s up and 27 Mbit/s down, and the
decryption loads the CPU heavily.

### Encrypted DNS (DoH)
**On by default:** DNS is encrypted, so its queries cannot be read or changed on the way.
* A lookup takes 70–80 ms, and 40 lookups at once 1.3–1.9 s.
* Devices keep their own DNS settings, so Android's Private DNS keeps working.

**To turn it off:** LuCI → *Services → HTTPS DNS Proxy* → *Stop* and *Disable*, or:
```sh
/etc/init.d/https-dns-proxy stop
/etc/init.d/https-dns-proxy disable
```
The router then asks the ISP's DNS again. Other DoH providers are set on the same page.

---

## Pre-installed Packages
* **Web interface:** LuCI with the pages for the status, the system, the network, Wi-Fi, the firewall, PPPoE and L2TP, WireGuard,
  AmneziaWG and IPv6.
  * It is in English and Russian, following the browser's language, with the Bootstrap theme.
  * It works over HTTP.
* **DNS:** `dnsmasq`, and `https-dns-proxy` with its LuCI page.
* **VPN:** `wireguard-tools` and `amneziawg-tools`, with their LuCI pages.
* **Wi-Fi:**
  * `wpad-basic-mbedtls`: WPA2/WPA3, 802.11r and 802.11w, and the client mode;
  * `travelmate` with its LuCI page;
  * `iw` and `iwinfo`.
* **The internet connection:** PPPoE, L2TP (`xl2tpd`), and IPv6 (`odhcp6c`, `odhcpd`).
* **Watchdog:** `watchcat` with its LuCI page. It does nothing until a rule is added in *Services → Watchcat*: a reboot or a
  restart of an interface when pings fail for a set time, or a reboot on a schedule.
* **Tools:** `curl`, and the busybox tools (`ip`, `ping`, `traceroute`, `nslookup`, `top`, `vi` and others).

---

## Building

[BUILDING.md](BUILDING.md): the build, the check in QEMU, changing the configuration and releases with GitHub Actions.

For developers: [UPGRADING.md](UPGRADING.md) lists the files of OpenWrt that this build changes and describes how to port it to a
new OpenWrt release.

---

## About OpenWrt Project

OpenWrt Project is a Linux operating system targeting embedded devices. Instead
of trying to create a single, static firmware, OpenWrt provides a fully
writable filesystem with package management. This frees you from the
application selection and configuration provided by the vendor and allows you
to customize the device through the use of packages to suit any application.
For developers, OpenWrt is the framework to build an application without having
to build a complete firmware around it; for users this means the ability for
full customization, to use the device in ways never envisioned.

### Support & Documentation

* [TP-Link Archer C50 on the OpenWrt wiki](https://openwrt.org/toh/tp-link/archer-c50)
* [The 4pda thread of the Archer A5](https://4pda.to/forum/index.php?showtopic=964235)
* [Support for the Archer C50 v4 on the OpenWrt forum](https://forum.openwrt.org/t/support-for-archer-c50-v4/20174)
* [Developer Documentation](https://openwrt.org/docs/guide-developer/start)

## License

OpenWrt is licensed under GPL-2.0
