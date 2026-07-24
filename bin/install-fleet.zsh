#!/bin/zsh
# Fleet installer — run by the human: launchd installs are user actions.
# This Mac gets the serve LaunchAgent (the tick agent is already loaded);
# each Mac mini gets tick + serve as system LaunchDaemons (headless-safe).
# Expect one sudo password prompt per mini.
set -e
REPO="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$REPO/bin/continuation"

echo "== this Mac: serve LaunchAgent =="
pkill -f "agentic-continuation serve" 2>/dev/null || true
"$BIN" install-serve-launchd

for ip in 192.168.50.4 192.168.50.5; do
  echo ""
  echo "== mini $ip: tick + serve LaunchDaemons (sudo password will be asked) =="
  ssh -t wezzard@$ip 'P=$(~/.local/bin/uv python find); B=~/Artifacts/Repositories/com.github/WeZZard/agentic-continuation/bin/continuation; sudo "$P" "$B" install-launchd --daemon && sudo "$P" "$B" install-serve-launchd --daemon'
done

echo ""
echo "== health check =="
launchctl list | grep agentic-continuation | sed 's/^/this Mac: /'
sleep 2
curl -s --max-time 5 http://127.0.0.1:7787/v1/node > /dev/null \
  && echo "this Mac: serve answering on :7787"
for ip in 192.168.50.4 192.168.50.5; do
  ssh wezzard@$ip 'H=$(scutil --get ComputerName); launchctl print system/com.wezzard.agent.agentic-continuation > /dev/null 2>&1 && echo "$H: tick daemon loaded"; launchctl print system/com.wezzard.agent.agentic-continuation.serve > /dev/null 2>&1 && echo "$H: serve daemon loaded"'
  curl -s --max-time 5 "http://$ip:7787/v1/node" > /dev/null \
    && echo "$ip: serve answering on :7787"
done
echo ""
echo "done — the Continuations app should now show all three nodes."
