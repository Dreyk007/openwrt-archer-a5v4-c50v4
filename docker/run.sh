#!/usr/bin/env bash
#
# Runs a command of this repository in the build container (docker/Dockerfile, Debian testing),
# with the checkout mounted at /work:
#
#   docker/run.sh ./build.sh                  # build as the user who owns the checkout
#   docker/run.sh --bench tests/qemu/bench.sh # QEMU bench: root with network admin rights
#   docker/run.sh                             # an interactive shell
#
# The image is rebuilt when docker/Dockerfile changes.

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BENCH=0
if [ "${1:-}" = "--bench" ]; then
    BENCH=1
    shift
fi

UID_HOST="$(id -u)"
GID_HOST="$(id -g)"
HASH="$(sha256sum "$REPO/docker/Dockerfile" | cut -c1-12)"
IMAGE="a5v4-build:$HASH-$UID_HOST"

if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
    echo "Building the container image $IMAGE..."
    docker build --pull --build-arg UID="$UID_HOST" --build-arg GID="$GID_HOST" \
        -t "$IMAGE" "$REPO/docker"
fi

ARGS=(--rm --init -v "$REPO:/work" -w /work -e HOST_UID="$UID_HOST" -e HOST_GID="$GID_HOST")
[ -t 0 ] && [ -t 1 ] && ARGS+=(-it)
if [ "$BENCH" = 1 ]; then
    # Network namespaces (unshare/nsenter) and tap devices for the LAN and WAN sides of the
    # emulated router; everything stays inside the network namespace of the container.
    ARGS+=(--user 0:0 --cap-add NET_ADMIN --cap-add SYS_ADMIN --device /dev/net/tun)
    # pppd of the PPPoE server on the WAN side
    [ -c /dev/ppp ] && ARGS+=(--device /dev/ppp)
else
    ARGS+=(--user "$UID_HOST:$GID_HOST" -e HOME=/home/builder)
fi

[ "$#" -gt 0 ] || set -- bash
exec docker run "${ARGS[@]}" "$IMAGE" "$@"
