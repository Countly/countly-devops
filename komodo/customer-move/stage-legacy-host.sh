#!/bin/bash
# Stage a legacy dockerized Countly host (tree in /opt/countly) for prod Komodo in the single
# /opt/countly layout. Run on the host, as root, after kernel-lts.sh.
#
#   /opt/countly/          customer files = COUNTLY_CUSTOMER_DIR (.env, ssl/, vhosts/, clickhouse/)
#   /opt/countly/komodo/   Periphery root: config, bin/periphery, keys/, stacks/<name>/compose
#   /opt/countly/legacy/   the legacy tree; rollback source until the first Deploy changes data
#   /mongodb-data /clickhouse-data /kafka-data   unchanged
#
# Subcommands, in this order:
#
#   sudo bash stage-legacy-host.sh legacy <TIER>
#       Moves /opt/countly/* into /opt/countly/legacy/, points the docker.service guard drop-in
#       at it, then RECREATES the legacy stack from there with `make up TIER=<TIER>` (about one
#       to two minutes of downtime). Without the recreate the running containers keep bind
#       mounts to paths that no longer exist, and the next restart or reboot breaks nginx and
#       alloy. <TIER> is the tier the legacy stack runs; the Makefile passes tiers/<TIER>.env,
#       which carries the memory limits and Node heaps (a bare `docker compose` does not, and
#       every container falls back to compose defaults: the jobserver OOM-loops at 1.5 GiB).
#
#   (install Periphery: setup-periphery.py --root-directory=/opt/countly/komodo, privileged
#    onboarding key; see README.md)
#
#   sudo bash stage-legacy-host.sh periphery
#       Moves the binary and config the installer put in /usr/local/bin and /etc/komodo into
#       /opt/countly/komodo; the systemd unit stays a regular file in /etc/systemd/system and
#       its ExecStart points there. Clears the onboarding key from the config once connected.
#
# Then: Komodo sync + Pull, and from /opt/countly/komodo/stacks/<name>/compose:
#   COUNTLY_CUSTOMER_DIR=/opt/countly bash scripts/migrate-legacy.sh /opt/countly/legacy --tier <T>
set -euo pipefail
NEW=/opt/countly
LEG=$NEW/legacy
KOM=$NEW/komodo
UNIT=/etc/systemd/system/periphery.service
TS=$(date -u +%Y%m%dT%H%M%SZ)

case "${1:-}" in
legacy)
  TIER="${2:?usage: stage-legacy-host.sh legacy <TIER> (the tier the legacy stack runs, e.g. T4-16)}"
  [ -f "$NEW/docker-compose.yml" ] && [ -f "$NEW/.env" ] && [ -f "$NEW/Makefile" ] || { echo "STOP: $NEW is not a legacy tree"; exit 1; }
  [ -f "$NEW/tiers/$TIER.env" ] || { echo "STOP: $NEW/tiers/$TIER.env does not exist"; exit 1; }
  [ ! -e "$LEG" ] || { echo "STOP: $LEG exists"; exit 1; }
  echo "  legacy .active-tier: $(cat "$NEW/.active-tier" 2>/dev/null || echo none); recreating with $TIER"
  DROPIN=$(grep -l '^ExecStartPre=/opt/countly/scripts/check-data-mounts.sh' /etc/systemd/system/docker.service.d/*.conf 2>/dev/null | head -1 || true)
  [ -n "$DROPIN" ] && [ ! -L "$DROPIN" ] || { echo "STOP: no docker.service drop-in with the legacy ExecStartPre"; exit 1; }
  OBS=""
  ! docker inspect countly-alloy >/dev/null 2>&1 || OBS=1
  cp -a "$DROPIN" "/root/$(basename "$DROPIN").bak-$TS"

  echo "== $NEW -> $LEG"
  mkdir "$LEG"
  find "$NEW" -mindepth 1 -maxdepth 1 ! -name legacy ! -name komodo -exec mv -t "$LEG" {} +

  echo "== docker start guard -> $LEG (backup /root/$(basename "$DROPIN").bak-$TS)"
  sed -i -e "s#^Environment=COUNTLY_DEPLOY_DIR=/opt/countly\$#Environment=COUNTLY_DEPLOY_DIR=$LEG#" \
         -e "s#^ExecStartPre=/opt/countly/scripts/check-data-mounts.sh\$#ExecStartPre=$LEG/scripts/check-data-mounts.sh#" "$DROPIN"
  grep -E 'COUNTLY_DEPLOY_DIR|ExecStartPre' "$DROPIN"
  systemctl daemon-reload
  COUNTLY_DEPLOY_DIR=$LEG "$LEG/scripts/check-data-mounts.sh" | tail -4 || { echo "STOP: guard dry run failed; fix before any Docker restart"; exit 1; }

  echo "== recreate the legacy stack from $LEG (make up TIER=$TIER${OBS:+ OBS=1})"
  ( cd "$LEG" && make up TIER="$TIER" ${OBS:+OBS=1} )
  echo "== bind mounts under /opt (all must be under $LEG)"
  docker ps -q | xargs docker inspect --format '{{range .Mounts}}{{if eq .Type "bind"}}{{.Source}}{{"\n"}}{{end}}{{end}}' \
    | grep '^/opt' | sed -E 's#^(/opt/countly/[^/]+).*#\1#' | sort | uniq -c
  docker compose ls
  curl -sk -o /dev/null -w "ping %{http_code}\n" --max-time 10 https://localhost/o/ping
  ;;
periphery)
  [ -x /usr/local/bin/periphery ] && [ -f /etc/komodo/periphery.config.toml ] || { echo "STOP: no fresh Periphery install"; exit 1; }
  grep -q "^root_directory = \"$KOM\"" /etc/komodo/periphery.config.toml || { echo "STOP: root_directory is not $KOM"; exit 1; }
  grep -q '/usr/local/bin/periphery --config-path /etc/komodo/periphery.config.toml' "$UNIT" || { echo "STOP: unexpected ExecStart"; exit 1; }
  [ ! -L "$UNIT" ] || { echo "STOP: $UNIT is a link"; exit 1; }
  [ ! -e "$KOM/periphery.config.toml" ] || { echo "STOP: $KOM/periphery.config.toml exists"; exit 1; }
  # An empty key means the installer got none (`read -rs K` on the same pasted line as the command).
  v=$(grep -E '^onboarding_key' /etc/komodo/periphery.config.toml | cut -d= -f2- | tr -d ' "')
  [ -n "$v" ] || { echo "STOP: onboarding_key is empty in /etc/komodo/periphery.config.toml"; exit 1; }
  systemctl disable --now periphery
  mkdir -p "$KOM/bin"
  mv /etc/komodo/periphery.config.toml "$KOM/periphery.config.toml"
  chmod 600 "$KOM/periphery.config.toml"
  find /etc/komodo -mindepth 1 -maxdepth 1 -exec mv -n -t "$KOM" {} +
  rmdir /etc/komodo
  mv /usr/local/bin/periphery "$KOM/bin/periphery"
  sed -i "s#/usr/local/bin/periphery --config-path /etc/komodo/periphery.config.toml#$KOM/bin/periphery --config-path $KOM/periphery.config.toml#" "$UNIT"
  grep ExecStart "$UNIT"
  systemctl daemon-reload
  systemctl enable --now periphery
  for i in $(seq 1 20); do
    journalctl -u periphery --since '-1 min' --no-pager | grep -qE 'onboarding flow .* successful|Logged in|Connected' && break
    journalctl -u periphery --since '-1 min' --no-pager | grep -q 'Onboarding failed' && { echo "STOP: onboarding failed:"; journalctl -u periphery -n 3 --no-pager | cut -c1-250; exit 1; }
    sleep 2
  done
  # The key is only needed for the first connection: clear it.
  sed -i -E 's|^onboarding_key[[:space:]]*=.*|onboarding_key = ""|' "$KOM/periphery.config.toml"
  systemctl restart periphery
  sleep 5; systemctl is-active periphery
  ls -A "$KOM"
  echo "Now disable the onboarding key in Komodo if it was for this host only."
  ;;
*) echo "usage: stage-legacy-host.sh legacy <TIER> | periphery"; exit 2 ;;
esac
