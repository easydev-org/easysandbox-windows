#!/bin/sh
# Remove every nat rule this project may have left behind, by line number.
#
# Runs INSIDE the container. It is a file rather than an inline docker exec string
# because the variables have to be expanded by this shell, not by the host: with double
# quotes the host expanded $chain to nothing and set -u aborted the loop, so the rules
# that hijack the published port survived every cleanup attempt.
set -u

for chain in PREROUTING POSTROUTING OUTPUT; do
  nums=$(iptables -t nat -L $chain --line-numbers -n 2>/dev/null | grep QEMU_DNAT | cut -d" " -f1 | sort -rn)
  for n in $nums; do
    iptables -t nat -D $chain $n 2>/dev/null || true
  done
done

iptables -t nat -F QEMU_DNAT 2>/dev/null || true
iptables -t nat -X QEMU_DNAT 2>/dev/null || true

echo "  PREROUTING after cleanup:"
iptables -t nat -S PREROUTING 2>/dev/null | head -8
