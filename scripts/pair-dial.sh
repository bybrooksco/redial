#!/usr/bin/env bash
# Scan for the Surface Dial and pair/trust/connect it.
set -uo pipefail

echo "Scanning up to 45s for Surface Dial..."
timeout 50 bluetoothctl --timeout 45 scan on >/dev/null 2>&1 &
SCAN_PID=$!

MAC=""
for _ in $(seq 1 45); do
  MAC=$(bluetoothctl devices 2>/dev/null | grep -i "Surface Dial" | awk '{print $2}' | head -1)
  [ -n "$MAC" ] && break
  sleep 1
done
# Found it (or gave up): stop scanning now rather than waiting out the full 45 s, so pairing starts
# while the dial is still in pairing mode.
bluetoothctl scan off >/dev/null 2>&1
kill $SCAN_PID 2>/dev/null
wait $SCAN_PID 2>/dev/null

if [ -z "$MAC" ]; then
  echo "No Surface Dial seen. Is the LED blinking? (hold pairing button 5-7s)"
  exit 1
fi

echo "Found Surface Dial at $MAC"
bluetoothctl pair "$MAC"
bluetoothctl trust "$MAC"
bluetoothctl connect "$MAC"
echo "--- info ---"
bluetoothctl info "$MAC"
