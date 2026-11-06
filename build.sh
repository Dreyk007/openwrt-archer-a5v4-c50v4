#!/usr/bin/env bash
#
# Build script of the TP-Link Archer A5 v4 / Archer C50 v4 build
# (MediaTek MT7628AN, ramips/mt76x8, mipsel_24kc, musl libc).
#
# Runs on a Debian/Ubuntu host or in the build container: docker/run.sh ./build.sh
# --qemu builds the same configuration for the QEMU bench (malta/le, the same mipsel_24kc
# programs) instead of the router.
#

set -euo pipefail

# Text colors
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
NC='\033[0m' # No Color

info() { echo -e "${BLUE}${BOLD}[INFO]${NC} $*"; }
success() { echo -e "${GREEN}${BOLD}[SUCCESS]${NC} $*"; }
warn() { echo -e "${YELLOW}${BOLD}[WARNING]${NC} $*"; }
error() { echo -e "${RED}${BOLD}[ERROR]${NC} $*"; }

# Ensure we run from the repository root
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

INSTALL_DEPS=0
CCACHE=0
QEMU=0
DEV=0
SEED="a5v4.config"
PROFILE="hybrid"
JOBS="$(nproc)"

# Size of the firmware partition of the Archer C50 v4 (IMAGE_SIZE in target/linux/ramips/image/mt76x8.mk)
FIRMWARE_KIB=7616

usage() {
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  -i, --install-deps    Install required build dependencies via apt (not needed in the container)"
    echo "      --seed <file>     Configuration seed (default: $SEED; reference.config is the official set)"
    echo "      --qemu            Build the seed for the QEMU bench (malta/le) instead of the router"
    echo "      --profile <name>  Compiler flags of the programs: hybrid (default; OpenWrt's -Os with"
    echo "                        MIPS16, ucode without MIPS16) or o2 (-O2 for the 24KEc, no MIPS16)"
    echo "      --ccache          Keep a compiler cache in .ccache, so that later builds only recompile what changed"
    echo "      --dev             Debug image for diagnostics on the router, not for release: debugfs of the"
    echo "                        kernel, mac80211 and mt76, kernel symbols, SysRq, perf events, tracepoints,"
    echo "                        hung task reports; kprof, udpblast, ethtool and iperf3 in the image, perf,"
    echo "                        tcpdump and strace as packages for /tmp; without AmneziaWG"
    echo "  -j<N>                 Number of parallel compilation jobs (default: $(nproc))"
    echo "  -h, --help            Show this help message"
}

# Parse optional arguments
while [ "$#" -gt 0 ]; do
    case "$1" in
        --install-deps|-i)
            INSTALL_DEPS=1
            ;;
        --seed)
            SEED="${2:?--seed needs a file}"
            shift
            ;;
        --seed=*)
            SEED="${1#--seed=}"
            ;;
        --qemu)
            QEMU=1
            ;;
        --profile)
            PROFILE="${2:?--profile needs a name}"
            shift
            ;;
        --profile=*)
            PROFILE="${1#--profile=}"
            ;;
        --ccache)
            CCACHE=1
            ;;
        --dev)
            DEV=1
            ;;
        -j*)
            JOBS="${1#-j}"
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            error "Unknown option: $1"
            usage
            exit 1
            ;;
    esac
    shift
done

# The compiler flags of the programs; the kernel has its own (-O2 from the seed). hybrid: OpenWrt's
# -Os with MIPS16, ucode without MIPS16 (its Makefile); o2: -O2 for the 24KEc with its DSP ASE and
# without MIPS16 (RESEARCH.md section 5).
case "$PROFILE" in
    hybrid)
        PROFILE_FLAGS=""
        ;;
    o2)
        PROFILE_FLAGS="-O2 -pipe -mno-branch-likely -march=24kec -mtune=24kec"
        ;;
    *)
        error "Unknown profile: $PROFILE (hybrid or o2)"
        exit 1
        ;;
esac

if [ "$QEMU" = 1 ]; then
    TARGET_DIR="bin/targets/malta/le"
    TARGET_NAME="QEMU bench (malta/le, mipsel_24kc)"
    KDIR="build_dir/target-mipsel_24kc_musl/linux-malta_le"
    ROOT="build_dir/target-mipsel_24kc_musl/root-malta"
else
    TARGET_DIR="bin/targets/ramips/mt76x8"
    TARGET_NAME="TP-Link Archer C50 v4 (ramips/mt76x8, MT7628AN)"
    KDIR="build_dir/target-mipsel_24kc_musl/linux-ramips_mt76x8"
    ROOT="build_dir/target-mipsel_24kc_musl/root-ramips"
fi

echo -e "${BOLD}================================================================${NC}"
echo -e "${BOLD} OpenWrt Firmware Build System — TP-Link Archer A5 v4 / C50 v4 ${NC}"
echo -e "${BOLD} Target: ${TARGET_NAME}${NC}"
echo -e "${BOLD} Seed:   ${SEED}${NC}"
echo -e "${BOLD} Programs: profile ${PROFILE}${NC}"
if [ "$DEV" = 1 ]; then
    echo -e "${BOLD} Debug image (--dev): diagnostics, not for release${NC}"
fi
echo -e "${BOLD}================================================================${NC}"

# 1. Install dependencies if requested or if essential build tools are missing
DEPS_PACKAGES=(
    build-essential
    ca-certificates
    clang
    flex
    bison
    g++
    gawk
    gcc-multilib
    g++-multilib
    gettext
    git
    libncurses-dev
    libssl-dev
    python3
    python3-dev
    python3-setuptools
    python3-pyelftools
    rsync
    swig
    unzip
    zlib1g-dev
    file
    wget
    curl
    time
    xz-utils
    zstd
)

if [ "$INSTALL_DEPS" -eq 1 ]; then
    info "Installing build dependencies via apt..."
    if [ "$(id -u)" -eq 0 ]; then
        apt-get update && apt-get install -y "${DEPS_PACKAGES[@]}"
    elif command -v sudo >/dev/null 2>&1; then
        sudo apt-get update && sudo apt-get install -y "${DEPS_PACKAGES[@]}"
    else
        error "Root or sudo privilege is required to install dependencies."
        exit 1
    fi
    success "Dependencies successfully installed."
else
    # Quick sanity check for essential tools
    MISSING_TOOLS=()
    for tool in gcc g++ make gawk bison flex git rsync swig; do
        if ! command -v "$tool" >/dev/null 2>&1; then
            MISSING_TOOLS+=("$tool")
        fi
    done
    if [ "${#MISSING_TOOLS[@]}" -gt 0 ]; then
        warn "Missing essential tools: ${MISSING_TOOLS[*]}"
        warn "Run '$0 --install-deps' or build in the container (docker/run.sh $0)."
    fi
fi

# Ensure FORCE_UNSAFE_CONFIGURE is exported if running as root
if [ "$(id -u)" -eq 0 ]; then
    warn "Running build as root is not recommended by OpenWrt. Setting FORCE_UNSAFE_CONFIGURE=1."
    export FORCE_UNSAFE_CONFIGURE=1
fi

# 2. Update and install package feeds
info "Updating and installing OpenWrt package feeds..."
./scripts/feeds update -a

# Fixes for feed packages: feeds-patches/<feed>/*.patch, applied in name order. A pinned feed is
# not updated once cloned, so first restore the files of every feed to its commit: that also drops
# what a patch removed since the last build had changed. A patch that does not apply, e.g. because
# the feed already has it, stops the build.
for feed_dir in feeds/*/; do
    [ -d "$feed_dir.git" ] && git -C "$feed_dir" checkout -q -- .
done
for feed_patches in feeds-patches/*/; do
    [ -d "$feed_patches" ] || continue
    feed_dir="feeds/$(basename "$feed_patches")"
    for patch in "$feed_patches"*.patch; do
        if ! git -C "$feed_dir" apply "$PWD/$patch"; then
            error "Feed patch $patch does not apply to $feed_dir."
            exit 1
        fi
        info "Applied feed patch $patch"
    done
done

./scripts/feeds install -a
success "Feeds updated and installed."

# 3. Apply target configuration
if [ ! -f "$SEED" ]; then
    error "Configuration seed '$SEED' not found in $(pwd)!"
    exit 1
fi

info "Applying configuration from $SEED..."
if [ "$QEMU" = 1 ]; then
    # The same seed on the malta/le target: the same mipsel_24kc programs and kernel options, but
    # PCI network cards and mac80211_hwsim instead of the switch and the radios of the router.
    # The Wi-Fi drivers of the router stay, so that the bench loads them (symbols, no hardware).
    {
        echo "CONFIG_TARGET_malta=y"
        echo "CONFIG_TARGET_malta_le=y"
        echo "CONFIG_TARGET_malta_le_Default=y"
        grep -v -E '^(# )?CONFIG_TARGET_(ramips|DEVICE_|MULTI_PROFILE|PER_DEVICE)' "$SEED"
        echo "CONFIG_PACKAGE_kmod-mac80211-hwsim=y"
        echo "CONFIG_PACKAGE_kmod-pcnet32=y"
        echo "CONFIG_PACKAGE_kmod-mt7603=y"
        echo "CONFIG_PACKAGE_kmod-mt76x2=y"
    } > .config
else
    cp "$SEED" .config
fi
if [ -n "$PROFILE_FLAGS" ]; then
    {
        echo "CONFIG_TARGET_OPTIONS=y"
        echo "CONFIG_TARGET_OPTIMIZATION=\"$PROFILE_FLAGS\""
        echo "# CONFIG_USE_MIPS16 is not set"
    } >> .config
fi
# The compiler cache is a build option and does not change the firmware; the seed leaves it off
if [ "$CCACHE" = 1 ]; then
    echo "CONFIG_CCACHE=y" >> .config
    info "Compiler cache enabled (.ccache)"
fi
# Debug image: what the router needs to show where the CPU and the radios spend their time and
# why a task hangs. The tools are built as packages and copied to /tmp of the router when needed
# (AGENTS.md); AmneziaWG goes, so that the larger kernel leaves room for the settings.
if [ "$DEV" = 1 ]; then
    sed -i '/amneziawg/d' .config
    {
        echo "CONFIG_KERNEL_DEBUG_FS=y"
        echo "CONFIG_PACKAGE_MAC80211_DEBUGFS=y"
        echo "CONFIG_KERNEL_MAGIC_SYSRQ=y"
        echo "CONFIG_KERNEL_KALLSYMS=y"
        echo "CONFIG_KERNEL_PERF_EVENTS=y"
        echo "CONFIG_KERNEL_FTRACE=y"
        echo "CONFIG_KERNEL_ENABLE_DEFAULT_TRACERS=y"
        # Debug information for decoding stack traces (vmlinux of the build tree; the image is
        # stripped). It also selects DEBUG_KERNEL, which the detectors below depend on.
        echo "CONFIG_KERNEL_DEBUG_INFO=y"
        echo "CONFIG_KERNEL_DETECT_HUNG_TASK=y"
        echo "CONFIG_KERNEL_SOFTLOCKUP_DETECTOR=y"
        echo "CONFIG_KERNEL_WQ_WATCHDOG=y"
        # In the image the small tools take flash, not RAM: a program in /tmp stays in RAM
        # whole. perf (about 2 MB compressed) does not fit and stays a package, as do tcpdump
        # and strace.
        echo "CONFIG_PACKAGE_a5v4-diag=y"
        echo "CONFIG_PACKAGE_ethtool=y"
        echo "CONFIG_PACKAGE_iperf3=y"
        echo "CONFIG_PACKAGE_perf=m"
        echo "CONFIG_PACKAGE_tcpdump=m"
        echo "CONFIG_PACKAGE_strace=m"
    } >> .config
    warn "Debug image (--dev): not for release"
fi
# Kernel options without a switch of their own: OpenWrt merges env/kernel-config last into the
# target configuration. /env is ignored by git, so the fragment is tracked as a5v4-kernel.config.
# The kernel is configured again when env/kernel-config changes, not when the symbol whitelist of
# TRIM_UNUSED_KSYMS does, so the fragment carries the whitelist's hash. The file is only written
# when its content changes: a newer one makes OpenWrt configure the kernel again.
# The debug image reports tasks stuck for 60 s instead of 120 s, adds /proc/<pid>/stack and exports
# all kernel symbols, so that the debugfs code of mac80211 and mt76 needs no whitelist. Options
# that OpenWrt has a switch for (CONFIG_KERNEL_*) go to .config above: OpenWrt applies those last.
DEV_KCONFIG=""
if [ "$DEV" = 1 ]; then
    DEV_KCONFIG="CONFIG_DEFAULT_HUNG_TASK_TIMEOUT=60
CONFIG_STACKTRACE=y
# CONFIG_TRIM_UNUSED_KSYMS is not set"
fi
if [ -f a5v4-kernel.config ]; then
    mkdir -p env
    {
        cat a5v4-kernel.config
        if [ -f a5v4-ksyms.txt ]; then
            echo "# a5v4-ksyms.txt $(sha256sum < a5v4-ksyms.txt | cut -d' ' -f1)"
        fi
        if [ -n "$DEV_KCONFIG" ]; then
            echo "$DEV_KCONFIG"
        fi
    } > env/kernel-config.new
    if cmp -s env/kernel-config.new env/kernel-config; then
        rm env/kernel-config.new
    else
        mv env/kernel-config.new env/kernel-config
    fi
    info "Kernel configuration fragment a5v4-kernel.config -> env/kernel-config"
elif [ -f env/kernel-config ]; then
    rm -f env/kernel-config
fi
make defconfig
PROGRAM_FLAGS="$(sed -n 's/^CONFIG_TARGET_OPTIMIZATION="\(.*\)"$/\1/p' .config)"
if grep -q '^CONFIG_USE_MIPS16=y' .config; then
    PROGRAM_FLAGS="$PROGRAM_FLAGS, MIPS16"
fi
if [ -n "$PROFILE_FLAGS" ] && [ "$PROGRAM_FLAGS" != "$PROFILE_FLAGS" ]; then
    error "Profile $PROFILE did not apply: the programs are built with $PROGRAM_FLAGS"
    exit 1
fi
success "Configuration applied successfully (programs: $PROGRAM_FLAGS)."

# The toolchain and the global compiler flags of the programs: OpenWrt rebuilds a package when its
# own options change, not when these do, and all GCC versions share one target staging directory
# (a GCC 14 tree built with GCC 15 linked procd against the host's libubox). A change of them, or
# an existing tree of unknown flags, needs a clean target build; the toolchain, the host tools and
# the downloads stay. Switching between the router and the QEMU bench does not change the key.
BUILD_KEY_FILE="build_dir/a5v4-build-key"
BUILD_KEY="$(grep -E '^(# )?CONFIG_(GCC_VERSION|LIBC|BINUTILS_VERSION|TARGET_OPTIMIZATION|EXTRA_OPTIMIZATION|USE_MIPS16|USE_LTO|USE_GC_SECTIONS|PKG_ASLR_PIE_[A-Z]+|PKG_CC_STACKPROTECTOR_[A-Z]+|PKG_FORTIFY_SOURCE_[0-9]|PKG_RELRO_[A-Z]+)[= ]' .config | sort)"
if [ -f "$BUILD_KEY_FILE" ]; then
    if [ "$(cat "$BUILD_KEY_FILE")" != "$BUILD_KEY" ]; then
        warn "The toolchain or the global compiler flags changed since the last build: make clean"
        diff "$BUILD_KEY_FILE" <(echo "$BUILD_KEY") || true
        make clean
    fi
elif compgen -G "build_dir/target-*" > /dev/null; then
    warn "A build tree without a recorded toolchain and compiler flags: make clean"
    make clean
fi
mkdir -p build_dir
echo "$BUILD_KEY" > "$BUILD_KEY_FILE"

# 4. Pre-download source packages
info "Pre-downloading package sources using $JOBS parallel jobs..."
make download -j"$JOBS"
success "Source downloads complete."

# 5. Compile firmware
# Timestamp of the files in the image: the date of this fork's last commit. Otherwise the
# release tag's version.date gives every build of a release the same one, and with it the
# same ?v= that LuCI appends to its scripts and styles (the mtime of /lib/apk/db/installed),
# so a browser can keep using the cached files of another build. A tree with uncommitted
# changes takes the time of the build instead: its builds differ from each other and from
# that commit. It is also the clock a router starts with after a factory reset, until NTP
# sets it.
SDE_ARGS=()
if SDE=$(git log -1 --no-show-signature --format=%ct 2>/dev/null) && [ -n "$SDE" ]; then
    SDE_FROM="the last commit"
    if ! git diff --quiet HEAD 2>/dev/null; then
        SDE=$(date +%s)
        SDE_FROM="the build, the tree has uncommitted changes"
    fi
    SDE_ARGS=("SOURCE_DATE_EPOCH=$SDE")
    info "SOURCE_DATE_EPOCH=$SDE ($(date -u -d "@$SDE" '+%F %T') UTC, $SDE_FROM)"
fi
# A module built outside the kernel tree (mac80211, mt76, amneziawg) that needs a symbol missing
# from the whitelist of TRIM_UNUSED_KSYMS would stop the build in modpost, before any
# kernel-symbols.txt is written. modpost only warns; the kernel check below stops the build and
# lists the symbols to add.
export KBUILD_MODPOST_WARN=1
info "Starting multi-threaded firmware compilation (-j$JOBS)..."
START=$(date +%s)
if ! make -j"$JOBS" "${SDE_ARGS[@]}"; then
    warn "Multi-threaded build failed. Retrying in single-thread debug mode (V=s)..."
    make -j1 V=s "${SDE_ARGS[@]}"
fi
success "Firmware compilation finished successfully in $(( ($(date +%s) - START) / 60 )) min."

# Packages of the image that the configuration does not select. A package keeps the dependencies of
# the configuration it was built with, and OpenWrt does not rebuild it when only a conditional
# dependency changes: base-files built with USE_SECCOMP pulls procd-seccomp into every later image.
# Prints each such package with the source directories of the packages that pull it in.
stale_packages() {
    python3 - .config tmp/.packageinfo "$ROOT/lib/apk/db/installed" <<'EOF'
import os, re, sys
config, packageinfo, installed = sys.argv[1:4]
selected = {m.group(1) for m in (re.match(r"CONFIG_PACKAGE_(\S+)=y$", l) for l in open(config)) if m}
expected, source = {"kernel"}, {}
pkg = abi = makefile = pkg_makefile = None
def add():
    # The name of the package file: an ABI version is appended, except for kmods (FormatABISuffix)
    if pkg in selected:
        suffix = ("-" if pkg[-1].isdigit() else "") + abi if abi and not pkg.startswith("kmod-") else ""
        expected.add(pkg + suffix)
        source[pkg + suffix] = os.path.dirname(pkg_makefile)
for line in open(packageinfo, errors="replace"):
    key, _, value = line.rstrip("\n").partition(": ")
    if key == "Source-Makefile":
        makefile = value
    elif key == "Package":
        add()
        pkg, abi, pkg_makefile = value, None, makefile
    elif key == "ABI-Version":
        abi = value
add()
names, deps = [], {}
for block in open(installed, errors="replace").read().split("\n\n"):
    fields = {l[0]: l[2:] for l in block.splitlines() if l[1:2] == ":"}
    if "P" in fields:
        names.append(fields["P"])
        deps[fields["P"]] = {re.split(r"[<>=~]", d)[0] for d in fields.get("D", "").split()}
for name in names:
    if name not in expected:
        print(name, *sorted({source.get(d, d) for d in names if name in deps[d]}))
EOF
}
if [ -f "$ROOT/lib/apk/db/installed" ]; then
    STALE="$(stale_packages)"
    if [ -n "$STALE" ]; then
        warn "Packages in the image that the configuration does not select (package: pulled in by):"
        echo "$STALE"
        for dir in $(echo "$STALE" | cut -d' ' -f2- | tr ' ' '\n' | sort -u); do
            info "Rebuilding $dir"
            make "package/$(basename "$dir")/clean" > /dev/null
        done
        make -j"$JOBS" "${SDE_ARGS[@]}"
        STALE="$(stale_packages)"
        if [ -n "$STALE" ]; then
            error "Packages in the image that the configuration does not select:"
            echo "$STALE"
            exit 1
        fi
        success "The image has only the packages of the configuration."
    fi
fi

# busybox installs a link for every applet into its install directory and never removes one: an
# applet that the configuration turns off keeps its link in the image, which then answers "applet
# not found" (ping6 and traceroute6 stayed after IPv6 was turned off). Prints the links of the image
# that are not in busybox.links of the build.
stale_applets() {
    local links
    links="$(first "$(dirname "$KDIR")"/busybox-*/busybox-*/busybox.links)"
    [ -n "$links" ] || return 0
    find "$ROOT" -type l -lname '*busybox' -printf '/%P\n' | sort | comm -23 - <(sort "$links")
}
first() { for f in "$@"; do [ -e "$f" ] && { echo "$f"; return 0; }; done; return 0; }
STALE="$(stale_applets)"
if [ -n "$STALE" ]; then
    warn "busybox links in the image without their applet: $(echo $STALE)"
    info "Rebuilding package/utils/busybox"
    make package/busybox/clean > /dev/null
    make -j"$JOBS" "${SDE_ARGS[@]}"
    STALE="$(stale_applets)"
    if [ -n "$STALE" ]; then
        error "busybox links in the image without their applet: $(echo $STALE)"
        exit 1
    fi
    success "The busybox links of the image match its applets."
fi

# Hits and misses of this build; the counters are reset afterwards, so that the next build
# shows its own
if [ "$CCACHE" = 1 ] && [ -x staging_dir/host/bin/ccache ]; then
    info "Compiler cache of this build:"
    CCACHE_DIR="$SCRIPT_DIR/.ccache" staging_dir/host/bin/ccache --show-stats || true
    CCACHE_DIR="$SCRIPT_DIR/.ccache" staging_dir/host/bin/ccache --zero-stats > /dev/null || true
fi

if [ ! -d "$TARGET_DIR" ]; then
    error "Target build directory '$TARGET_DIR' not found!"
    exit 1
fi

# 6. Size report: what the image takes of the flash and the kernel of the RAM
kib() { echo $(( ($(stat -c %s "$1") + 1023) / 1024 )); }
REPORT="$TARGET_DIR/size-report.txt"
# The toolchain of this configuration: other GCC versions built before stay in staging_dir
GCC_VERSION="$(sed -n 's/^CONFIG_GCC_VERSION="\(.*\)"$/\1/p' .config)"
TOOLCHAIN="staging_dir/toolchain-mipsel_24kc_gcc-${GCC_VERSION}_musl/bin/mipsel-openwrt-linux-musl"
# The kernel of the image, not linux-*/vmlinux: that one is the last kernel built, with the
# initramfs of the initramfs image in its .init.data
VMLINUX="$(first "$KDIR/vmlinux.elf")"
MODDIR="$(first "$ROOT"/lib/modules/*/)"
{
    echo "Build: $(git log -1 --format='%h %s' 2>/dev/null)$(git diff --quiet HEAD 2>/dev/null || echo ' (uncommitted changes)')"
    echo "Seed: $SEED; target: $TARGET_NAME"
    echo "Programs: profile $PROFILE ($PROGRAM_FLAGS)"
    if [ "$QEMU" = 0 ]; then
        SYSUPGRADE="$(first "$TARGET_DIR"/*tplink_archer-c50-v4-squashfs-sysupgrade.bin)"
        if [ -n "$SYSUPGRADE" ]; then
            IMG_KIB=$(kib "$SYSUPGRADE")
            echo "Image: $IMG_KIB KiB ($(basename "$SYSUPGRADE"))"
            echo "Free for settings: $((FIRMWARE_KIB - IMG_KIB)) KiB of $FIRMWARE_KIB KiB"
        fi
        KERNEL_BIN="$(first "$KDIR"/tplink_archer-c50-v4-kernel.bin)"
        if [ -n "$KERNEL_BIN" ]; then
            echo "Kernel in flash: $(kib "$KERNEL_BIN") KiB"
        fi
        if [ -f "$KDIR/root.squashfs" ]; then
            echo "root.squashfs: $(kib "$KDIR/root.squashfs") KiB"
        fi
    fi
    if [ -n "$VMLINUX" ] && [ -x "$TOOLCHAIN-size" ]; then
        "$TOOLCHAIN-size" "$VMLINUX" | awk 'NR == 2 {
            printf "Kernel in RAM: %d KiB (text %d, data %d, bss %d KiB)\n",
                ($1 + $2 + $3) / 1024, $1 / 1024, $2 / 1024, $3 / 1024 }'
    fi
    if [ -n "$MODDIR" ] && [ -x "$TOOLCHAIN-size" ] && compgen -G "$MODDIR*.ko" > /dev/null; then
        # Each module takes whole pages for its code and its data on top of this
        "$TOOLCHAIN-size" "$MODDIR"*.ko | awk 'NR > 1 { s += $1 + $2 + $3; n++ } END {
            printf "Loadable modules in the image: %d, %d KiB (text + data + bss)\n", n, s / 1024 }'
    elif [ -d "$ROOT/lib/modules" ]; then
        echo "Loadable modules in the image: 0"
    fi
    # Unpacked size of the programs and libraries: what their code can take of the page cache
    if [ -d "$ROOT" ]; then
        (cd "$ROOT" && find bin sbin lib usr/bin usr/sbin usr/lib -path lib/modules -prune -o \
            -type f \( -perm -u+x -o -name '*.so*' \) -print0 2>/dev/null | xargs -0 -r stat -c %s) |
            awk '{ s += $1 } END { printf "Programs and libraries, unpacked: %d KiB\n", s / 1024 }'
        PROGRAMS=""
        for f in bin/busybox usr/sbin/wpad usr/lib/libucode.so.* usr/sbin/dnsmasq usr/sbin/uhttpd sbin/rpcd \
                 sbin/netifd sbin/procd usr/sbin/pppd usr/lib/libmbedcrypto.so.*.*.* lib/libc.so; do
            for g in "$ROOT"/$f; do
                if [ -f "$g" ]; then
                    PROGRAMS="$PROGRAMS${PROGRAMS:+, }$(basename "$g" | sed 's/\.so.*/.so/') $(kib "$g")"
                fi
            done
        done
        if [ -n "$PROGRAMS" ]; then
            echo "Of them (KiB): $PROGRAMS"
        fi
    fi
} | tee "$REPORT"

# 7. Kernel checks
CHECKS_FAILED=0
# The fragment: OpenWrt's own options win over it, and a kernel update can rename or drop an
# option. On the QEMU target some options of the router do not exist (its LEDs, its USB PHY).
KCONFIG_FINAL="$(first "$KDIR"/linux-*/.config)"
if [ -f a5v4-kernel.config ] && [ -n "$KCONFIG_FINAL" ]; then
    KCONFIG_EXPECTED="$(grep -E '^(# )?CONFIG_' a5v4-kernel.config)"
    if [ -n "$DEV_KCONFIG" ]; then
        # The lines of the debug image replace those of the same options; without
        # TRIM_UNUSED_KSYMS the option of its whitelist does not exist
        DEV_SYMS="$(echo "$DEV_KCONFIG" | sed -E 's/^(# )?(CONFIG_[A-Z0-9_]+).*/\2/' | paste -sd '|')"
        KCONFIG_EXPECTED="$(echo "$KCONFIG_EXPECTED" | grep -Ev "^(# )?($DEV_SYMS|CONFIG_UNUSED_KSYMS_WHITELIST)[= ]"; echo "$DEV_KCONFIG")"
    fi
    KCONFIG_MISSING="$(echo "$KCONFIG_EXPECTED" | grep -Fxv -f "$KCONFIG_FINAL" || true)"
    if [ -n "$KCONFIG_MISSING" ]; then
        if [ "$QEMU" = 1 ]; then
            warn "Lines of a5v4-kernel.config that the QEMU kernel does not have:"
        else
            error "Lines of a5v4-kernel.config that are not in the kernel configuration ($KCONFIG_FINAL):"
            CHECKS_FAILED=1
        fi
        echo "$KCONFIG_MISSING"
    fi
fi
# The symbols the modules of the image take from the kernel (kernel-symbols.txt). With
# TRIM_UNUSED_KSYMS the kernel exports only what the modules of its own tree and the whitelist
# a5v4-ksyms.txt ask for, so a module built outside the tree (mac80211, mt76, ...) does not load
# ("Unknown symbol") unless the whitelist covers it. The whitelist is the union of
# kernel-symbols.txt of the router and of the QEMU build. What the modules export to each other is
# in the symvers files of the kernel tree and of the out-of-tree packages; the modules of the image
# carry no symbol table.
# Exports of the kernel: the names of its __ksymtab entries (struct kernel_symbol of 32-bit MIPS:
# value, name and namespace pointers). __ksymtab_strings alone does not list them: the linker
# stores a name such as _printk in the tail of another (_dev_printk).
kernel_exports() {
    python3 - "$1" <<'EOF'
import struct, sys
from elftools.elf.elffile import ELFFile
with open(sys.argv[1], "rb") as f:
    elf = ELFFile(f)
    strings = elf.get_section_by_name("__ksymtab_strings")
    data = strings.data()
    fmt = "<I" if elf.little_endian else ">I"
    for name in ("__ksymtab", "__ksymtab_gpl"):
        table = elf.get_section_by_name(name)
        if table is None:
            continue
        raw = table.data()
        for i in range(0, len(raw), 12):
            off = struct.unpack_from(fmt, raw, i + 4)[0] - strings["sh_addr"]
            print(data[off:data.index(b"\0", off)].decode())
EOF
}
if [ -n "$MODDIR" ] && [ -n "$VMLINUX" ] && [ -x "$TOOLCHAIN-nm" ] && compgen -G "$MODDIR*.ko" > /dev/null; then
    KSYMS_TMP="$(mktemp -d)"
    for m in "$MODDIR"*.ko; do "$TOOLCHAIN-nm" -u "$m" | awk '$1 == "U" { print $2 }'; done | sort -u > "$KSYMS_TMP/needed"
    for m in "$MODDIR"*.ko; do basename "$m" .ko; done > "$KSYMS_TMP/names"
    cat "$KDIR"/linux-*/Module.symvers "$KDIR"/symvers/*.symvers 2> /dev/null |
        awk -F '\t' 'NR == FNR { image[$1] = 1; next } { n = split($3, p, "/") } image[p[n]] { print $2 }' \
            "$KSYMS_TMP/names" - | sort -u > "$KSYMS_TMP/modules"
    comm -23 "$KSYMS_TMP/needed" "$KSYMS_TMP/modules" > "$TARGET_DIR/kernel-symbols.txt"
    kernel_exports "$VMLINUX" | sort -u > "$KSYMS_TMP/kernel"
    KSYMS_MISSING="$(comm -23 "$TARGET_DIR/kernel-symbols.txt" "$KSYMS_TMP/kernel")"
    rm -rf "$KSYMS_TMP"
    info "The modules of the image take $(wc -l < "$TARGET_DIR/kernel-symbols.txt") symbols from the kernel ($TARGET_DIR/kernel-symbols.txt)"
    if [ -n "$KSYMS_MISSING" ]; then
        error "The kernel does not export symbols that modules of the image need; add them to a5v4-ksyms.txt:"
        echo "$KSYMS_MISSING"
        CHECKS_FAILED=1
    fi
fi
if [ "$CHECKS_FAILED" = 1 ]; then
    exit 1
fi

# 8. Generate and verify sha256sums
info "Generating and validating sha256sums in $TARGET_DIR..."
(
    cd "$TARGET_DIR"
    FILES_TO_HASH=()
    for f in config.buildinfo feeds.buildinfo version.buildinfo profiles.json openwrt-*.manifest \
             openwrt-*-sysupgrade.bin openwrt-*-initramfs-kernel.bin \
             openwrt-*-vmlinux-initramfs.elf openwrt-*-vmlinux.elf openwrt-*-rootfs-squashfs.img.gz; do
        if [ -f "$f" ]; then
            FILES_TO_HASH+=("$f")
        fi
    done
    sha256sum -b "${FILES_TO_HASH[@]}" > sha256sums
    sha256sum -c sha256sums
)
success "sha256sums generated and verified."

# 9. Print build summary
echo ""
echo -e "${BOLD}================================================================${NC}"
echo -e "${GREEN}${BOLD} Build Completed Successfully!                                 ${NC}"
echo -e "${BOLD} Artifacts location: ${TARGET_DIR}                             ${NC}"
echo -e "${BOLD}================================================================${NC}"
ls -lh "$TARGET_DIR"/openwrt-* "$TARGET_DIR"/sha256sums
echo ""
