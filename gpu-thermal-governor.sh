#!/bin/bash
# Dynamic GPU clock governor for GB10 / ASUS GX10.
#
# The graphics-clock cap (nvidia-smi -lgc) is the only software thermal lever on
# GB10 (no OS fan control; nvidia-smi -pl is N/A; no devfreq/sysfs GPU freq node).
#
# Control input is the hottest board zone (acpitz), read NATIVELY from
# /sys/class/thermal. That board temp is the trip driver: it runs ~10 C hotter
# than the GPU die and reaches the cutoff first. Reading it from sysfs needs no
# nvidia-smi subprocess, so the loop is cheap and polls fast enough to catch the
# quick board spikes that prefill/compute bursts cause. nvidia-smi is used ONLY
# to apply a cap change (rare: on a step), never to read.
#
# The loop floats the cap between MIN_CLK and MAX_CLK to hold the board in a
# target band: steps DOWN when hot, UP when cool, with a hard panic drop near the
# cutoff. On a well-cooled unit it rides near the ceiling; on a marginal one it
# settles low. (If yours floors out, read the README and CHECK THE FAN FIRST.)
#
# Setting the clock needs root. Either run this as root, or grant passwordless
# sudo for nvidia-smi and start it with SMI="sudo -n nvidia-smi".
set -u

MIN_CLK=${MIN_CLK:-1500}      # floor MHz
MAX_CLK=${MAX_CLK:-3003}      # ceiling MHz (stock max; lower it to force a hard cap)
STEP=${STEP:-150}             # MHz per adjustment
ZONE_HI=${ZONE_HI:-88}        # step DOWN at/above this board (acpitz) temp (C)
ZONE_LO=${ZONE_LO:-84}        # step UP at/below this (hysteresis band ZONE_LO..ZONE_HI)
ZONE_PANIC=${ZONE_PANIC:-92}  # hard slam to the floor at/above this
# Fork defaults (dydan77): intervene earlier than upstream (91/87/94). On a Dell Pro Max
# GB10 the board peaked at 93.1 C (10-min max) under sustained LLM load without tripping;
# the real cutoff is undocumented, so keep margin. Idle (~45 C) never touches the cap.
INTERVAL=${INTERVAL:-3}       # poll seconds (cheap: native sysfs read)

SMI=${SMI:-nvidia-smi}        # set to "sudo -n nvidia-smi" when running unprivileged
HEARTBEAT=${HEARTBEAT:-20}     # also log board+power every N iters when steady (0=off)
MAX_ITERS=${MAX_ITERS:-28800} # ~24h at 3s; clean exit -> supervisor respawns fresh

read_board() {  # hottest acpitz zone, native sysfs, no nvidia-smi
  local z v hi=0
  for z in /sys/class/thermal/thermal_zone*/temp; do
    [ -r "$z" ] || continue
    v=$(( $(cat "$z") / 1000 )); [ "$v" -gt "$hi" ] && hi=$v
  done
  echo "$hi"
}

# GPU-rail power in W. nvidia-smi only (no sysfs node), so read it only when we
# are about to log, never in the hot control path. Note: this is the GPU rail,
# not whole-system draw (module TDP ~140 W, system up to ~180 W, PSU 240 W).
read_power() { timeout 10 $SMI --query-gpu=power.draw --format=csv,noheader,nounits 2>/dev/null | tr -dc '0-9.'; }

# Apply a cap and report failure instead of assuming success (upstream ignored the
# exit status, so a failed -lgc silently left the GPU uncapped while the log said capped).
apply_cap() {
  if timeout 10 $SMI -lgc 0,"$1" >/dev/null 2>&1; then return 0; fi
  echo "$(date '+%H:%M:%S') WARN: nvidia-smi -lgc 0,$1 failed (cap NOT applied)" >&2
  return 1
}

# Restore stock clocks on any exit (stop, restart, crash in the loop, MAX_ITERS).
# Upstream left the last cap in place, so stopping the governor while it was at the
# floor kept the GPU slow until reboot.
reset_clocks() { timeout 10 $SMI -rgc >/dev/null 2>&1 && echo "governor exit: clocks reset (-rgc)"; }
trap reset_clocks EXIT
trap 'exit 0' TERM INT

timeout 10 $SMI -pm 1 >/dev/null 2>&1
cur=$MAX_CLK
apply_cap "$cur"
echo "governor start: cap=${cur} band[min=${MIN_CLK} max=${MAX_CLK}] target=${ZONE_LO}-${ZONE_HI} panic=${ZONE_PANIC} step=${STEP} interval=${INTERVAL}s"

iter=0
while [ "$iter" -lt "$MAX_ITERS" ]; do
  iter=$(( iter + 1 ))
  board=$(read_board)
  new=$cur
  if   [ "$board" -ge "$ZONE_PANIC" ]; then
    new=$MIN_CLK                                       # panic: slam to floor
  elif [ "$board" -ge "$ZONE_HI" ]; then
    new=$(( cur - STEP )); [ "$new" -lt "$MIN_CLK" ] && new=$MIN_CLK
  elif [ "$board" -le "$ZONE_LO" ]; then
    new=$(( cur + STEP )); [ "$new" -gt "$MAX_CLK" ] && new=$MAX_CLK
  fi
  if [ "$new" -ne "$cur" ]; then
    cur=$new
    apply_cap "$cur"
    echo "$(date '+%H:%M:%S') board=${board}C power=$(read_power)W -> cap=${cur}MHz"
  elif [ "$HEARTBEAT" -gt 0 ] && [ $(( iter % HEARTBEAT )) -eq 0 ]; then
    echo "$(date '+%H:%M:%S') board=${board}C power=$(read_power)W cap=${cur}MHz (steady)"
  fi
  sleep "$INTERVAL"
done
echo "governor: reached MAX_ITERS=${MAX_ITERS}, exiting for clean restart"
