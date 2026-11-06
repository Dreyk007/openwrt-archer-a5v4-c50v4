#!/bin/sh
# Read test of the SPI flash at higher clocks, with the test clock parameters of spi-mt7621
# (target/linux/ramips/patches-6.12/950-*). Reads the parts of the flash that do not change, all
# but the settings (rootfs_data), at the clock of the device tree for reference, then each test
# clock several times, and compares the SHA-256; stops at the first difference. Each clock also
# gets the raw read rate of rootfs (no checksum). Read-only. The clock goes back to the device
# tree's at the end.
# -r sets test_read_speed_hz, the clock of the Fast Read alone (a device tree with
# m25p,fast-read): status, write and erase commands keep the device tree's clock.
# Usage: sh spitest.sh [-r] <rounds> <Hz> [<Hz> ...]
P=/sys/module/spi_mt7621/parameters/test_speed_hz
if [ "$1" = -r ]; then
  shift; P=/sys/module/spi_mt7621/parameters/test_read_speed_hz
  grep -q "^ read.*0x0b" /sys/kernel/debug/spi-nor/spi0.0/params 2>/dev/null ||
    echo "warning: the flash is not read with Fast Read (0x0b), -r changes nothing"
fi
[ -w $P ] || { echo "no $P: this kernel lacks the test clock"; exit 1; }
echo "parameter: $P"
N=${1:-3}; shift
SYS=$(dmesg | sed -n 's/.*spi-mt7621.*sys_freq: \([0-9]*\).*/\1/p' | head -n 1); SYS=${SYS:-193333333}
hex() { printf '%d' "0x$1"; }
dev() { awk -v n="\"$1\"" '$4 == n { sub(":", "", $1); print $1 }' /proc/mtd; }
sz() { hex "$(awk -v n="\"$1\"" '$4 == n { print $2 }' /proc/mtd)"; }
# The squashfs of rootfs ends where rootfs_data begins
RLEN=$(( $(sz rootfs) - $(sz rootfs_data) ))
readall() {
  for p in $(awk -F'"' '/^mtd/ { print $2 }' /proc/mtd); do
    case $p in firmware|rootfs_data) continue;; esac
    if [ $p = rootfs ]; then head -c $RLEN /dev/$(dev $p); else cat /dev/$(dev $p); fi | sha256sum | cut -c1-16 | sed "s/^/$p:/"
  done | tr '\n' ' '
}
BYTES=0; for p in $(awk -F'"' '/^mtd/ { print $2 }' /proc/mtd); do case $p in firmware|rootfs_data) ;; rootfs) BYTES=$((BYTES + RLEN));; *) BYTES=$((BYTES + $(sz $p)));; esac; done
up() { cut -d' ' -f1 /proc/uptime; }
# 64 KiB per read(): mtdchar sends one SPI message per read, so smaller reads measure the
# overhead per message (head -c reads 4 KiB and gets a third less)
raw() {
  c=$((RLEN / 65536))
  t0=$(up); dd if=/dev/$(dev rootfs) of=/dev/null bs=65536 count=$c 2>/dev/null; t1=$(up)
  echo "$t0 $t1 $((c * 65536))" | awk '{printf "raw read of rootfs %.2f s, %.2f MB/s", $2-$1, $3/($2-$1)/1e6}'
}
echo 0 > $P
t0=$(up); REF="$(readall)"; t1=$(up)
echo "reference at the device tree's clock: $BYTES bytes in $(echo "$t0 $t1" | awk '{print $2-$1}') s"
echo "$REF"
echo "$(raw)"
for f in "$@"; do
  rate=$(( (SYS + f - 1) / f )); [ $rate -lt 2 ] && rate=2; real=$(( SYS / rate ))
  echo "$f" > $P
  i=0; bad=0
  while [ $i -lt $N ]; do
    i=$((i+1)); t0=$(up); got="$(readall)"; t1=$(up)
    if [ "$got" = "$REF" ]; then r=same; else r=DIFFERENT; bad=1; fi
    echo "$(( real / 1000 )) kHz (divider $rate), round $i: $r, $(echo "$t0 $t1 $BYTES" | awk '{printf "%.1f s, %.2f MB/s", $2-$1, $3/($2-$1)/1e6}')"
    [ $bad = 1 ] && { echo "$got"; break; }
  done
  [ $bad = 1 ] && break
  echo "$(( real / 1000 )) kHz: $(raw)"
done
echo 0 > $P
echo "clock back to the device tree's"
