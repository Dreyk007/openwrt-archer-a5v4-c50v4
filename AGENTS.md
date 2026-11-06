# AGENTS.md

Guidance for AI coding agents (and people) working on this repository.

**Read the documentation first:** `README.md` and `README.ru.md` (for users; a placeholder until the
first release), `UPGRADING.md` (every file this fork adds or changes, and how it is ported to a new
OpenWrt release), `RESEARCH.md` (the measurements and source checks behind the defaults; each
section ends with its decision, so do not propose a rejected option again without new data) and
`TODO.md` (the plan of the first release, what is still to be checked and measured, open
decisions, patches to drop once upstream has the fix, deferred candidates). `BUILDING.md` follows
with the first release. OpenWrt's own `.github/llm-review-rules.md` applies to patches. This file
only adds what those documents do not cover.

The build follows [openwrt-ax3200](https://github.com/Dreyk007/openwrt-ax3200), a sibling build for
the Xiaomi AX3200: the same structure of the documentation and the same way of working. Its
decisions do not carry over by themselves. This router has 8 MiB of flash, 64 MiB of RAM, one MIPS
core, no hardware NAT and no package manager in the image.

## Rules

- **The owner approves the contents of the image.** No package, kernel option or feature goes in
  or out without the owner's approval, given with its measured cost and what is lost
  (`RESEARCH.md` section 10 lists what is approved so far).
- **Measure before changing a default**, and record the setup, method, numbers and decision in
  `RESEARCH.md`.
- **Every change states its flash and RAM cost.** The firmware partition is 7616 KiB, and what the
  image does not use is all the room for settings. Record the size of the image, of `root.squashfs`
  and of the kernel before and after a change ([UPGRADING.md appendix B](UPGRADING.md#appendix-b-flash-and-ram-budget-check)).
- **Threat model:** attacks from the WAN and from Wi-Fi clients that are not authorised; the LAN
  and authorised Wi-Fi clients are trusted. Judge protections and their removal by it
  (`RESEARCH.md` section 9).
- **Keep the documentation of the fork complete:** a new file or an edit of an upstream file goes
  into the table in `UPGRADING.md` section 1.1, a new assumption about upstream into the
  checklist in section 3.6.
- **The owner's devices:** flashing, rebooting or changing the configuration of the owner's
  router needs the owner's explicit OK for that step. Before the first flash of a unit, its full
  flash dump must exist: every partition of [RESEARCH.md section 1](RESEARCH.md#1-hardware-flash-layout-and-installation)
  (`cat /dev/mtdN` on OpenWrt, a programmer on the stock firmware).
- **No secrets in the repository:** addresses, user names and keys of the owner's machines and
  networks stay out of the files and commit messages.

## Building and testing

- Builds run on a build PC in a Docker container (`docker/Dockerfile`, `debian:testing`):
  `docker/run.sh ./build.sh --ccache` (`--profile o2` for the other flags of the programs; a change of
  profile rebuilds every package), on an ext4 file system (not on an NTFS volume, which
  breaks the OpenWrt build). `--seed reference.config` builds the official package set for size
  comparisons. A full build takes long: run it in the background and check its log.
- **QEMU first.** Every image is tested on the QEMU bench before it goes to the router:
  `docker/run.sh ./build.sh --qemu --ccache`, then `docker/run.sh --bench tests/qemu/bench.sh`
  (malta/le with the same `mipsel_24kc` programs, `-cpu 24KEc -m 64`; `--official` boots the
  official malta image, `--shell` leaves a shell on the LAN side, `--hook <file>` runs a bash
  snippet with the bench's helpers instead of the tests, for debugging). A new feature gets its
  check in the bench. QEMU cannot show speed (TCG
  emulation), the radios, the switch or the flash layout; those are tested on the router. The
  checks are listed in `TODO.md`.
- On QEMU's malta the first `-nic` is the onboard card (PCI slot `0x0b`) and becomes `eth0`; the
  bench passes the LAN card first. The `--qemu` and router builds share one tree: `build.sh`
  rewrites `.config` from the seed every time.
- A single package: `make package/<name>/compile` after `make defconfig` with the package
  selected. LuCI apps build through `feeds/luci/luci.mk`, so the feeds must be installed.
- The image has no package manager, so a package cannot be installed on the router. To test one
  without reflashing, unpack the `.apk` on the build host with the host `apk`
  (`staging_dir/host/bin/apk extract`), copy the files with `scp -O` and restart the service; a
  reboot or a sysupgrade brings back the image's files. Measurement tools (`iperf3`, `ethtool`)
  go to `/tmp` the same way. Otherwise flash a test image.
- **Kernel modules:** with `TRIM_UNUSED_KSYMS` a module only loads into the kernel it was built
  with, and only if every symbol it needs is in the whitelist. After a change of the kernel or of a
  module, check `dmesg` for `Unknown symbol` and that `lsmod` lists all Wi-Fi modules.
- **Kernel options:** OpenWrt applies its `CONFIG_KERNEL_*` options and the `KCONFIG` of the
  selected `kmod-*` packages after the target configuration and `env/kernel-config`. Check the
  final `build_dir/target-*/linux-ramips_mt76x8/linux-*/.config`, not the fragment.
- **Diagnostics** need the debug image, `./build.sh --dev` (never released): debugfs of the
  kernel, mac80211 and mt76, kernel symbols (`/proc/kallsyms`, `/proc/<pid>/stack`), SysRq, perf
  events and tracepoints, reports of hung tasks (60 s), soft lockups and stalled workqueues, all
  kernel symbols exported; `kprof`, `udpblast`, `ethtool`, `iperf3` and the scripts of
  `tests/router` (`/usr/share/a5v4-diag`) are in the image, `perf`, `tcpdump` and `strace` are
  built as packages for `/tmp`. It leaves out AmneziaWG to keep room for the settings. The `vmlinux` with
  debug information stays in the build tree to decode stack traces.
  `/sys/kernel/debug/ieee80211/phy0/mt76/radio` shows the sensitivity and the false CCA counts of
  the 2.4 GHz radio.
- **RAM of the debug image:** about 12 MB available instead of 18. Every MB in `/tmp` comes out of
  the page cache, and below about 6 MB the router re-reads its programs from the flash (10 MHz SPI,
  1 MiB squashfs blocks) and spends the CPU on that. A program in the image costs only the pages
  it runs; one in `/tmp` stays in RAM whole. So `perf` (6 MB unpacked, 2 MB compressed, too large
  for the flash) stays out; profile with `kprof` and load Wi-Fi with `udpblast`. To try a change of
  them without a new image, build them with the toolchain of the tree in the container:
  `export STAGING_DIR=$PWD/staging_dir; staging_dir/toolchain-mipsel_24kc_gcc-*_musl/bin/mipsel-openwrt-linux-musl-gcc
  -O2 -march=24kec -s -o tmp/kprof tests/router/kprof.c`.
- The Ethernet ports are 100 Mbit/s: wired throughput tests only show the CPU load at line rate.
  The CPU-bound paths are Wi-Fi ↔ Wi-Fi, Wi-Fi client (WISP) ↔ LAN and WireGuard.
- If the agent reaches the router over Wi-Fi, start commands that restart Wi-Fi detached on the
  router, or the session dies with the link. The same holds for the WISP client: a scan of the
  client interface stops the access points of that radio.
- `pkill -f <pattern>` kills the shell that runs it when the pattern is part of its own command
  line (e.g. `ssh host 'pkill -f …'`); keep a PID file instead.
- Recovery: UART next to the Ethernet ports (115200 8N1), `4` at boot for the U-Boot console, TFTP
  recovery with `tp_recovery.bin` from `192.168.0.66` ([RESEARCH.md section 1](RESEARCH.md#1-hardware-flash-layout-and-installation)).

## LuCI and ucode

The build has no own LuCI app yet. If it gets one, follow the layout of `luci-app-tuning` in
openwrt-ax3200: a JS view, an rpcd ucode plugin in `root/usr/share/rpcd/ucode/<name>.uc` returning
`{ 'luci.<name>': methods }`, `menu.d`, `acl.d`, `po/templates/*.pot` and `po/ru/*.po` (the image
carries LuCI in Russian and English).

- rpc calls time out: run anything that touches the network in the background
  (`(cmd) </dev/null >/dev/null 2>&1 &`) and let the page poll a status file. An rpcd plugin waits
  for the commands it runs, and rpcd answers nothing else meanwhile.
- `E('p', E('a', …))` renders an empty `<p>`: a single element as the second argument is taken
  for the attributes. Write `E('p', {}, E(…))` or pass an array.
- ucode: a syntax check is `ucode <file>` on the router; an rpcd plugin loads with
  `ucode -e 'loadfile("<file>")()'`.
- LuCI caches the menu tree per session in the browser: a renamed menu entry shows after the next
  login.

## Writing for users

- Plain language for users. Implementation details (patch numbers, file paths, how something was
  fixed, internal tooling) belong in `UPGRADING.md` and `RESEARCH.md`, not in the README.
- `README.md` and `README.ru.md` change together; so will `BUILDING.md` and `BUILDING.ru.md`,
  which follow with the first release.
- The firmware is published on GitHub and in the 4pda thread of the Archer A5: users install it
  from the stock firmware, without a package manager afterwards. Spell out what the build leaves
  out and what each setup (WISP, WireGuard, IPTV) needs.
- UI texts: say what happens and what it costs, with measured numbers where there are some.
- Code comments are in English only.

## Commits

- Work on `a5v4-25.12`. Commit messages: `<area>: <what>` (`build:`, `docs:`, `mt76:`,
  `ramips:` …), a body that explains why, with measurements (sizes!) where they matter.
- Commits in this fork carry no AI attribution trailers (no `Co-Authored-By`). They are signed
  with the owner's key through the repository's git configuration; do not bypass it.
- Combine related commits before they are pushed. Push only when the owner asks; never rewrite
  pushed history without the owner's explicit OK.

## Upstream contributions

- Fixes that matter beyond this device go upstream: kernel and OpenWrt patches to
  openwrt/openwrt, Wi-Fi driver fixes to openwrt/mt76 and linux-wireless, LuCI fixes to openwrt/luci.
- Prepare them on separate branches from the upstream branch, authored under the owner's real
  name (OpenWrt does not accept pseudonyms), with `Assisted-by: LLM` and a sentence in the PR
  that discloses the AI assistance. The agent never adds `Signed-off-by` and never sends or opens
  anything: the owner reviews, signs off and submits.
- A patch file submitted to OpenWrt starts with a `From <sha> Mon Sep 17 00:00:00 2001` line, or
  its bot flags it. Check commits with OpenWrt's formality checker
  (`openwrt/actions-shared-workflows`, `check_formalities.sh`) before they are submitted. A
  stable-branch backport (`[25.12]`) follows the merge in main and carries
  `(cherry picked from commit …)`.

Waiting upstream (update this list when one is merged or closed, and drop the fork's copy as
`TODO.md` describes):

| Change in this fork | Submitted as |
|---|---|
| mt7603: let the dynamic sensitivity start from 0 (own fix, `RESEARCH.md` section 6) | not yet: submit to openwrt/mt76 after the test on the router |
| ramips: rt3050-esw: keep the WAN port disabled until it is configured (`RESEARCH.md` section 1) | not yet: checked on the router, to submit to openwrt/openwrt |
| https-dns-proxy: keep the backup of an empty dnsmasq server list (`feeds-patches/packages/0001-*.patch`, `RESEARCH.md` section 14) | not yet: submit to openwrt/packages |

## Working with the owner

- Plan larger features first and get the plan approved.
- Tests on the owner's devices go step by step, each with the owner's consent; say what a step
  does (reboot, minutes without network) before asking.
- Report what actually happened, including failed steps and results that contradict an earlier
  conclusion.
