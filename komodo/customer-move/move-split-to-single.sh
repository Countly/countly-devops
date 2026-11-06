#!/bin/bash
# Move a Komodo-managed Countly host from the split layout to a single /opt/countly. No symlinks.
#   /opt/countly-2601/*  -> /opt/countly/*        customer files (COUNTLY_CUSTOMER_DIR)
#   /opt/komodo          -> /opt/countly/komodo   Periphery root (config, bin/, keys/, stacks/)
#   old legacy tree in /opt/countly (if any) -> /opt/countly/legacy/, except data/, which stays
#   (test-ui and demo-ui keep their datastores in /opt/countly/data: no data disks there).
# Also points the Periphery unit's ExecStart and the docker.service guard drop-in at the new paths.
#
# Running containers keep working (their bind mounts follow the moved directories), but nothing
# may restart them until the Komodo Deploy recreates them from the new paths. Order: merge the
# countly-deployment PR, run this, run the customers-docker sync, Deploy. Never Deploy a stack
# whose synced config says /opt/countly before this has run: pre-install would seed a fresh .env.
#
# Usage: sudo bash move-split-to-single.sh <stack-name>
set -euo pipefail
NAME="${1:?usage: move-split-to-single.sh <stack-name>}"
OLD=/opt/countly-2601
OLDKOM=/opt/komodo
NEW=/opt/countly
KOM=$NEW/komodo
UNIT=/etc/systemd/system/periphery.service
TS=$(date -u +%Y%m%dT%H%M%SZ)

echo "== checks ($NAME)"
[ -f "$OLD/.env" ]                       || { echo "STOP: $OLD/.env missing (already moved?)"; exit 1; }
[ -d "$OLDKOM/stacks/$NAME/compose" ]    || { echo "STOP: $OLDKOM/stacks/$NAME/compose missing"; exit 1; }
[ -x "$OLDKOM/bin/periphery" ]           || { echo "STOP: $OLDKOM/bin/periphery missing"; exit 1; }
[ ! -e "$KOM" ] && [ ! -e "$NEW/legacy" ] || { echo "STOP: $KOM or $NEW/legacy already exists"; exit 1; }
grep -q "$OLDKOM/bin/periphery --config-path $OLDKOM/periphery.config.toml" "$UNIT" \
                                         || { echo "STOP: $UNIT ExecStart is not the expected one"; exit 1; }
[ ! -L "$UNIT" ]                         || { echo "STOP: $UNIT is a link"; exit 1; }
DROPIN=$(grep -l "COUNTLY_DEPLOY_DIR=$OLDKOM/stacks/$NAME/compose" /etc/systemd/system/docker.service.d/*.conf 2>/dev/null | head -1 || true)
[ -n "$DROPIN" ] && [ ! -L "$DROPIN" ]   || { echo "STOP: no docker.service drop-in with COUNTLY_DEPLOY_DIR=$OLDKOM/stacks/$NAME/compose"; exit 1; }
# A running container may bind only data/ out of the old tree: everything else in it moves.
bad=$(docker ps -q | xargs -r docker inspect --format '{{range .Mounts}}{{if eq .Type "bind"}}{{.Source}}{{"\n"}}{{end}}{{end}}' \
      | grep -E "^$NEW(/|\$)" | grep -vE "^$NEW/data(/|\$)" || true)
[ -z "$bad" ]                            || { echo "STOP: running containers bind these from $NEW: $bad"; exit 1; }
# Customer file names must not collide with what stays in /opt/countly.
for f in "$OLD"/.[!.]* "$OLD"/*; do
  [ -e "$f" ] || continue
  b=$(basename "$f")
  [ "$b" != data ] && [ "$b" != legacy ] && [ "$b" != komodo ] || { echo "STOP: $OLD/$b would clash"; exit 1; }
done
cp -a "$OLD/.env" "/root/countly-env.bak-$TS"
cp -a "$UNIT" "/root/periphery.service.bak-$TS"
cp -a "$DROPIN" "/root/$(basename "$DROPIN").bak-$TS"
echo "  ok; backups in /root (*-$TS)"

echo "== stop Periphery (Komodo shows the server unreachable for a minute)"
systemctl disable --now periphery

if [ -d "$NEW" ]; then
  echo "== legacy tree -> $NEW/legacy (data/ stays)"
  mkdir "$NEW/legacy"
  find "$NEW" -mindepth 1 -maxdepth 1 ! -name data ! -name legacy -exec mv -t "$NEW/legacy" {} +
else
  mkdir -m 0755 "$NEW"
fi

echo "== customer files: $OLD -> $NEW"
find "$OLD" -mindepth 1 -maxdepth 1 -exec mv -t "$NEW" {} +
rmdir "$OLD"
sed -i -E "s#^(COUNTLY_(ENV_FILE|VHOSTS_DIR|SSL_DIR|CLICKHOUSE_DIR))=$OLD#\1=$NEW#" "$NEW/.env"
grep -E '^COUNTLY_(ENV_FILE|VHOSTS_DIR|SSL_DIR|CLICKHOUSE_DIR)=' "$NEW/.env"
! grep -q "$OLD" "$NEW/.env" || { echo "WARNING: $NEW/.env still names $OLD:"; grep -n "$OLD" "$NEW/.env" | cut -d= -f1; }

echo "== Periphery: $OLDKOM -> $KOM"
mv "$OLDKOM" "$KOM"
sed -i "s#^root_directory = .*#root_directory = \"$KOM\"#" "$KOM/periphery.config.toml"
grep -E '^(root_directory|connect_as|core_address)' "$KOM/periphery.config.toml"
sed -i "s#$OLDKOM/bin/periphery --config-path $OLDKOM/periphery.config.toml#$KOM/bin/periphery --config-path $KOM/periphery.config.toml#" "$UNIT"
grep -q "$KOM/bin/periphery --config-path $KOM/periphery.config.toml" "$UNIT" || { echo "STOP: ExecStart not updated"; exit 1; }

echo "== docker start guard -> $KOM/stacks/$NAME/compose"
sed -i "s#$OLDKOM/stacks/#$KOM/stacks/#g" "$DROPIN"
grep -E 'COUNTLY_DEPLOY_DIR|ExecStartPre' "$DROPIN"

systemctl daemon-reload
systemctl enable --now periphery
sleep 3
systemctl is-active periphery
[ -d /etc/countly ] && rmdir /etc/countly 2>/dev/null && echo "  removed empty /etc/countly" || true

echo
echo "DONE ($NAME). The stack's .env links still point to $OLD until the Deploy: pre-install recreates them."
echo "Next, in Komodo: run the customers-docker sync (Update Stack $NAME), then Stacks > $NAME > Deploy."
