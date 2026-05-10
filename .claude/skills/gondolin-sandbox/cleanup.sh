#!/usr/bin/env bash
# SessionEnd hook: best-effort cleanup of any leaked QEMU VMs spawned by
# the gondolin skill during this session.
#
# Each one-shot `gondolin exec` should clean up its own QEMU on exit, but
# if the hook process is killed mid-flight QEMU can be reparented to PID
# 1. We can't reliably distinguish OUR qemu processes from any other
# gondolin VMs the user runs, so this hook does nothing destructive by
# default. Set GONDOLIN_KILL_ALL_QEMU=1 to opt in to a blanket
# `pkill qemu-system-aarch64` on session end.
set -uo pipefail

if [ "${GONDOLIN_KILL_ALL_QEMU:-0}" = "1" ]; then
  pkill -9 -f 'qemu-system-aarch64' 2>/dev/null || true
fi

exit 0
