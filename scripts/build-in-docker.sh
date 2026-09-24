#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-only

# Builds the EC firmware in a disposable Ubuntu 22.04 container using the
# period-correct SDCC (4.0.0+dfsg-2, matching this repo's CI at the commit
# this branch is based on: 01be30f107c7930b0673d9f6a35058603f00bd63).
#
# This exists because a newer host-installed SDCC (e.g. 4.5.0 on Ubuntu
# 26.04) hits a real optimizer regression on this era's code:
#   error 110: conditional flow changed by optimizer: so said EVELYN the
#   modified DOG
# on src/board/system76/common/smfi.c, unrelated to any board-specific
# change. Building with the SDCC version this code was actually validated
# against avoids that entirely, without installing anything on the host.
#
# Usage: bin/build-in-docker.sh [BOARD]
#   BOARD defaults to system76/darp8.

set -eE

function msg {
  echo -e "\x1B[1m$*\x1B[0m" >&2
}

trap 'msg "\x1B[31mBuild failed!"' ERR

BOARD="${1:-system76/darp8}"
IMAGE="ubuntu:22.04"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

if ! command -v docker >/dev/null 2>&1; then
  msg "docker is required but not found on PATH"
  exit 1
fi

# Idempotent: always start from a clean build/ directory. A stale build/
# from a different branch/commit (different directory layout) will produce
# confusing "No rule to make target" errors from leftover SDCC -MMD .d files.
msg "Cleaning build/ directory"
rm -rf build

msg "Building $BOARD in a disposable $IMAGE container"
docker run --rm \
  -v "$REPO_ROOT:/repo" \
  -w /repo \
  "$IMAGE" \
  bash -c "
    set -e
    apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      sdcc make binutils xxd git ca-certificates -qq
    git config --global --add safe.directory /repo
    make BOARD=$BOARD
    # The container runs as root, so fix ownership of anything written into
    # the bind-mounted build/ directory before handing back to the host user.
    # This must happen inside the container: root here maps to the numeric
    # host UID/GID directly on a bind mount, but the host user itself has no
    # permission to chown root-owned files after the fact.
    chown -R $(id -u):$(id -g) /repo/build
  "

msg "Built build/ec.rom for $BOARD"
