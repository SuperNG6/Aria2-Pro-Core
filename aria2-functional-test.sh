#!/usr/bin/env bash
#
# Copyright (c) 2020 P3TERX <https://p3terx.com>
#
# This is free software, licensed under the GNU General Public License v3.
# See /LICENSE for more information.
#
# https://github.com/P3TERX/Aria2-Pro-Core
# File name: aria2-functional-test.sh
# Description: Aria2 functional testing
# Version: 1.0
#

set -euo pipefail

ARIA2_BIN="${ARIA2_BIN:-./output/aria2c}"

if [[ ! -x "$ARIA2_BIN" ]]; then
    echo "Aria2 binary not found: $ARIA2_BIN" >&2
    exit 1
fi

$ARIA2_BIN https://raw.githubusercontent.com/P3TERX/aria2.conf/master/dht.dat
$ARIA2_BIN https://raw.githubusercontent.com/P3TERX/aria2.conf/master/dht6.dat
ARCH_TORRENT=$(curl -sSL "https://geo.mirror.pkgbuild.com/iso/latest/" | \
    grep -oE 'archlinux-[0-9]{4}\.[0-9]{2}\.[0-9]{2}-x86_64\.iso\.torrent' | head -1)
[ -n "$ARCH_TORRENT" ] || { echo "Failed to resolve Arch Linux torrent filename"; exit 1; }
$ARIA2_BIN \
    --seed-time=0 \
    --enable-dht6=true \
    --dht-file-path="$PWD/dht.dat" \
    --dht-file-path6="$PWD/dht6.dat" \
    --dht-entry-point='dht.transmissionbt.com:6881' \
    --dht-entry-point6='dht.transmissionbt.com:6881' \
    "https://geo.mirror.pkgbuild.com/iso/latest/${ARCH_TORRENT}"
