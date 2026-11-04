#!/bin/bash
# build-on-vm.sh -- turn a copy of the countly-enterprise base image into the Komodo base image.
#
#   sudo bash build-on-vm.sh build     strip the legacy tree and credentials, install guard,
#                                      Periphery and the registry helper, pre-pull images
#   sudo bash build-on-vm.sh check     read-only: success criteria 1-2 (run after a cold boot)
#   sudo bash build-on-vm.sh seal      generalise and power off; the next step is cutting the image
#
# Runs ONLY on the build VM (komodo-base-build). Never on new-arch-base-image or a customer host.
set -euo pipefail

BUNDLE_COMMIT=933803efd4d07ae8fe249e3331d45661698b4d52     # tag 27.0.0-rc1 (lane main-rc; on no branch)
PERIPHERY_VERSION=v2.3.3
PERIPHERY_SHA256=40b78f377626799afad8331246a501f077d4ebcfb6d9096894cf55b64f6dcf13  # periphery-x86_64, GitHub release digest
GCR_HELPER_VERSION=2.2.1
GCR_HELPER_SHA256=54733a03c18f230059d89e8976518de9af16cebb74b86ccab5c95c9da66f5912  # linux_amd64 tar.gz, GitHub release digest
REGISTRIES=gcr.io,us-docker.pkg.dev,europe-docker.pkg.dev

# One directory for everything Countly-related; data stays on the /*-data disks.
CUSTOMER_DIR=/opt/countly
KOMODO_DIR=/opt/countly/komodo
BUILD_TMP=/root/komodo-base-build

log()  { printf '\n==> %s\n' "$*"; }
fail() { printf 'FATAL: %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || fail "run with sudo"
# build and seal change the machine: only on the build VM. check is read-only and also runs on test VMs.
case "${1:-}:$(hostname -s)" in build:komodo-base-build|seal:komodo-base-build|check:*|:*) ;;
  *) fail "'${1:-}' runs only on komodo-base-build, not $(hostname -s)" ;; esac

# root's leftovers from the legacy image and from this build. Found 2026-11-02 in the first cut:
# /root/opt-countly-backup-2026091812*.tar.gz (old tree WITH ssl/privkey.pem), gcloud's
# credentials.db/access_tokens.db (written by `gcloud auth configure-docker`), .viminfo.
# Keeps .bashrc, .profile and .docker (credHelpers only).
clean_root() {
  rm -rf /root/opt-countly-backup-* /root/*.tar /root/*.tar.gz /root/*.tgz \
         /root/.config/gcloud /root/.cache /root/.local /root/snap \
         /root/.viminfo /root/.lesshst /root/.bash_history /root/.wget-hsts /root/.python_history \
         /root/.ssh/authorized_keys
}

build() {
  log "1/8 Remove the legacy tree, the GCR key, saved registry logins and root's leftovers"
  # The legacy dockerized_deploy tree lives in /opt/countly too: removed here, rebuilt empty in step 3.
  systemctl stop docker.socket docker
  rm -rf /opt/countly /opt/gcr-key.json
  rm -f /root/.docker/config.json /home/*/.docker/config.json
  clean_root
  # Docker stays down until step 3: the legacy drop-in's ExecStartPre names the deleted
  # /opt/countly/scripts/check-data-mounts.sh, so a start now fails with 203/EXEC.

  # compose-release is private and the VM holds no GitHub credential: the builder copies
  # `git archive <commit> compose` here as /tmp/bundle.tar, and its commit is checked.
  log "2/8 Unpack the bundle at ${BUNDLE_COMMIT:0:7}"
  [ -f /tmp/bundle.tar ] || fail "copy the bundle first: git archive --format=tar ${BUNDLE_COMMIT} compose > bundle.tar"
  [ "$(git get-tar-commit-id < /tmp/bundle.tar)" = "$BUNDLE_COMMIT" ] || fail "/tmp/bundle.tar is not ${BUNDLE_COMMIT}"
  rm -rf "$BUILD_TMP"
  install -d -m 0700 "$BUILD_TMP"
  tar -xf /tmp/bundle.tar -C "$BUILD_TMP"
  B="$BUILD_TMP/compose"

  log "3/8 Docker tuning and the data-disk guard, pointed at ${CUSTOMER_DIR} (starts Docker)"
  install -d -m 0755 "$CUSTOMER_DIR/scripts"
  install -m 0755 "$B/scripts/check-data-mounts.sh" "$CUSTOMER_DIR/scripts/check-data-mounts.sh"
  # COUNTLY_DEPLOY_DIR makes the drop-in carry Environment=COUNTLY_DEPLOY_DIR=$CUSTOMER_DIR and
  # ExecStartPre=$CUSTOMER_DIR/scripts/check-data-mounts.sh. No .env there yet, so the guard passes.
  COUNTLY_DEPLOY_DIR="$CUSTOMER_DIR" bash "$B/scripts/provision-docker-host.sh" fine-tune
  systemctl is-active -q docker || fail "docker did not start with the new drop-in"

  log "4/8 Drop every old image, container and volume"
  docker ps -aq | xargs -r docker rm -f
  docker system prune -a --volumes -f

  log "5/8 Periphery ${PERIPHERY_VERSION} in ${KOMODO_DIR} (linked, not enabled, no core, no keys)"
  install -d -m 0755 "$KOMODO_DIR/bin"
  install -d -m 0700 "$KOMODO_DIR/keys"
  curl -fsSL -o "$KOMODO_DIR/bin/periphery.new" \
    "https://github.com/moghtech/komodo/releases/download/${PERIPHERY_VERSION}/periphery-x86_64"
  echo "${PERIPHERY_SHA256}  $KOMODO_DIR/bin/periphery.new" | sha256sum -c -
  chmod 0755 "$KOMODO_DIR/bin/periphery.new"
  mv "$KOMODO_DIR/bin/periphery.new" "$KOMODO_DIR/bin/periphery"
  cat > "$KOMODO_DIR/periphery.config.toml" <<EOF
# Komodo Periphery -- baked into the base image with no identity.
# countly_ignite adds core_address, connect_as and a one-time onboarding_key per server,
# then removes the onboarding_key. Keys are generated on first start in ${KOMODO_DIR}/keys.
root_directory = "${KOMODO_DIR}"
EOF
  chmod 0600 "$KOMODO_DIR/periphery.config.toml"
  cat > "$KOMODO_DIR/periphery.service" <<EOF
[Unit]
Description=Agent to connect with Komodo Core
After=network-online.target docker.service
Wants=network-online.target

[Service]
Environment="HOME=/root"
ExecStart=/bin/sh -lc "${KOMODO_DIR}/bin/periphery --config-path ${KOMODO_DIR}/periphery.config.toml"
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF
  systemctl link "$KOMODO_DIR/periphery.service"
  systemctl daemon-reload

  # Not gcloud's helper: it is a snap, and a snap run as root joins root's user systemd manager
  # when one is up (any SSH + sudo session). Closing that session kills the helper mid-pull
  # ("error getting credentials - err: signal: terminated"): ignite-rehearsal-2, 2026-11-04.
  # docker-credential-gcr is one static binary that reads the token from the metadata server.
  log "6/8 Registry access through the VM's service account (docker-credential-gcr ${GCR_HELPER_VERSION}, no stored password)"
  curl -fsSL -o /tmp/gcr-helper.tgz \
    "https://github.com/GoogleCloudPlatform/docker-credential-gcr/releases/download/v${GCR_HELPER_VERSION}/docker-credential-gcr_linux_amd64-${GCR_HELPER_VERSION}.tar.gz"
  echo "${GCR_HELPER_SHA256}  /tmp/gcr-helper.tgz" | sha256sum -c -
  tar -xzf /tmp/gcr-helper.tgz -C /tmp docker-credential-gcr
  install -m 0755 /tmp/docker-credential-gcr /usr/local/bin/docker-credential-gcr
  rm -f /tmp/gcr-helper.tgz /tmp/docker-credential-gcr
  # Writes credHelpers only (no auths) into /root/.docker/config.json.
  docker-credential-gcr configure-docker --registries="$REGISTRIES"

  log "7/8 Pre-pull the ${BUNDLE_COMMIT:0:7} images"
  grep -hE '^[A-Z_]+_IMAGE=' "$B/images.standard.env" "$B/images.app.env" | cut -d= -f2- | sort -u |
    while read -r img; do docker pull -q "$img"; done
  rm -rf "$BUILD_TMP" /tmp/bundle.tar

  # MongoDB 8.x refuses kernels 6.19-7.0.13 by `uname -r` (SERVER-121912), and Ubuntu's 7.0 GCP
  # kernel reports 7.0.0 though it carries the fix: mongo 8.3.11 (26.10.2, 27.0.0-rc1) will not start on it.
  # The LTS track (6.8) stays below 6.19 and keeps security updates; the HWE metapackages go, so
  # unattended upgrades never bring a 6.17/7.x kernel back.
  log "8/8 Ubuntu's LTS GCP kernel (6.8) instead of the HWE kernels (6.17, 7.0)"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y -qq linux-gcp-lts-24.04 >/dev/null
  apt-get purge -y -qq linux-gcp linux-image-gcp linux-headers-gcp >/dev/null 2>&1 || true
  # The running kernel is one of these: answer "don't abort" to linux-base's removal question.
  echo 'linux-base linux-base/removing-running-kernel boolean false' | debconf-set-selections
  local hwe
  hwe="$(dpkg-query -W -f '${Package}\n' 'linux-*' | grep -E -- '-(6\.(19|[2-9][0-9])|6\.1[7-8]|[7-9]\.[0-9]+)\.[0-9]+-[0-9]+(-gcp)?$|linux-gcp-(6\.1[7-9]|[7-9]\.[0-9]+)-' || true)"
  [ -z "$hwe" ] || apt-get purge -y -qq $hwe >/dev/null
  ls /boot/vmlinuz-6.8.* >/dev/null 2>&1 || fail "no 6.8 kernel in /boot"
  # A hard reset right after this loses the unwritten /boot and grub.cfg: GRUB then boots the
  # deleted kernel, whose modules are gone, and the data mounts and Docker fail.
  sync

  log "Done. Next: cold boot (gcloud compute instances reset), then: sudo bash build-on-vm.sh check"
}

check() {
  local bad=0
  ok()  { printf '  ok    %s\n' "$*"; }
  no()  { printf '  FAIL  %s\n' "$*"; bad=1; }

  log "Criteria 1-2 (after a cold boot)"
  [ ! -e /opt/gcr-key.json ]   && ok "/opt/gcr-key.json absent"   || no "/opt/gcr-key.json exists"
  # No legacy file survived: only the guard and Periphery, nothing customer-specific yet.
  [ "$(ls -A "$CUSTOMER_DIR" | tr '\n' ' ')" = "komodo scripts " ] && ok "$CUSTOMER_DIR holds only komodo/ and scripts/" || no "$CUSTOMER_DIR: $(ls -A "$CUSTOMER_DIR" | tr '\n' ' ')"
  if REGISTRIES="$REGISTRIES" python3 -c 'import json,os,sys; c=json.load(open("/root/.docker/config.json")); h=c.get("credHelpers") or {}; sys.exit(0 if not c.get("auths") and all(h.get(r)=="gcr" for r in os.environ["REGISTRIES"].split(",")) and set(h.values())=={"gcr"} else 1)' 2>/dev/null; then
    ok "/root/.docker/config.json: credHelpers -> gcr only, no auths"
  else
    no "/root/.docker/config.json has auths, or a registry not on docker-credential-gcr"
  fi
  grep -q "${GCR_HELPER_VERSION}" <<<"$(docker-credential-gcr version 2>&1)" && ok "docker-credential-gcr ${GCR_HELPER_VERSION}" || no "docker-credential-gcr ${GCR_HELPER_VERSION} missing"
  # Names only, never contents. Where a deployer or an operator puts keys, not package or image
  # layer trees (/usr, /var/lib/docker, /var/lib/containerd, /snap carry public test fixtures).
  # /etc/ssh host keys are regenerated per VM and removed by `seal`.
  local keys
  keys="$(grep -rlI --exclude-dir={docker,containerd,snapd} -e '-----BEGIN [A-Z ]*PRIVATE KEY-----' \
    /opt /root /home /etc /srv /var/lib /tmp /var/tmp 2>/dev/null | grep -v '^/etc/ssh/' || true)"
  [ -z "$keys" ] && ok "no PEM private keys where deployments keep them" || no "private keys found in: $keys"
  # Keys inside archives (the plain-text scan above cannot see them): member names only.
  local f arch="" members
  while IFS= read -r f; do
    members="$(tar -tf "$f" 2>/dev/null || true)"
    grep -qiE '(privkey|\.key$|key\.json$|\.env$)' <<<"$members" && arch="$arch $f"
  done < <(find /opt /root /home /srv /tmp /var/tmp -xdev -type f \( -name '*.tar' -o -name '*.tar.gz' -o -name '*.tgz' \) 2>/dev/null)
  [ -z "$arch" ] && ok "no archives holding keys or .env files" || no "archives with key-like members:$arch"
  # Credential stores and editor/shell history in root's home. On a test VM run check before any
  # `docker pull`: the gcloud helper writes /root/.config/gcloud at run time, which is expected then.
  local leftovers
  leftovers="$(ls -d /root/.config/gcloud /root/.viminfo /root/.bash_history /root/.lesshst /root/opt-countly-backup-* 2>/dev/null || true)"
  [ -z "$leftovers" ] && ok "no credential stores or history in /root" || no "found in /root: $(tr '\n' ' ' <<<"$leftovers")"
  systemctl is-active -q docker && ok "docker active" || no "docker not active"
  # SERVER-121912: MongoDB 8.x refuses 6.19 <= uname -r < 7.0.14, whatever Ubuntu backported.
  local kv
  kv="$(uname -r)"
  [[ "$kv" =~ ^6\.8\. ]] && ok "kernel $kv (LTS, below 6.19)" || no "kernel $kv is not the 6.8 LTS kernel"
  ! dpkg-query -W -f '${Status}\n' linux-image-gcp 2>/dev/null | grep -q '^install ok installed' \
    && ok "HWE metapackage linux-image-gcp absent" || no "linux-image-gcp installed (pulls 7.x kernels back)"
  # systemd prints `code=exited ; status=0 }`; the guard itself logs its deploy dir to the journal.
  # Captured first: under pipefail, `cmd | grep -q` fails when grep exits early and SIGPIPEs cmd.
  local pre jrn
  pre="$(systemctl show docker -p ExecStartPre)"
  jrn="$(journalctl -b -u docker --no-pager)"
  grep -qE "${CUSTOMER_DIR}/scripts/check-data-mounts.sh.*code=exited ; status=0[ /}]" <<<"$pre" \
    && grep -q "Using deploy dir: ${CUSTOMER_DIR}\$" <<<"$jrn" \
    && ok "guard (${CUSTOMER_DIR}) ran this boot, status=0" || no "guard did not run from ${CUSTOMER_DIR} with status=0 this boot"
  ! systemctl is-enabled -q periphery 2>/dev/null && ok "periphery not enabled" || no "periphery enabled"
  ! systemctl is-active -q periphery && ok "periphery inactive" || no "periphery active"
  [ -z "$(ls -A "$KOMODO_DIR/keys")" ] && ok "$KOMODO_DIR/keys empty" || no "$KOMODO_DIR/keys not empty"
  ! grep -qE '^(core_address|core_addresses|connect_as|onboarding_key)' "$KOMODO_DIR/periphery.config.toml" \
    && ok "periphery config has no core/identity" || no "periphery config has core/identity lines"
  grep -q "${PERIPHERY_VERSION#v}" <<<"$("$KOMODO_DIR/bin/periphery" --version 2>/dev/null)" && ok "periphery ${PERIPHERY_VERSION}" || no "periphery version"
  echo
  [ "$bad" -eq 0 ] && echo "ALL CHECKS PASSED" || { echo "SOME CHECKS FAILED"; exit 1; }
}

seal() {
  log "Generalise and power off (the next SSH would undo this: cut the image straight after)"
  cloud-init clean --logs || true
  truncate -s 0 /etc/machine-id
  rm -f /var/lib/dbus/machine-id
  rm -f /etc/ssh/ssh_host_*
  apt-get clean
  journalctl --rotate && journalctl --vacuum-time=1s
  rm -rf /tmp/* /var/tmp/*
  clean_root
  # Every login account (UID 1000-59999), not just its home: the guest agent recreates them on
  # each VM from project ssh-keys metadata, but only if the account does not exist. Deleting only
  # /home leaves accounts it cannot repair, and SSH then fails with "Permission denied (publickey)".
  local u
  for u in $(awk -F: '$3>=1000 && $3<60000 {print $1}' /etc/passwd); do
    echo "removing account $u"
    userdel -f -r "$u" 2>/dev/null || userdel -f "$u"
  done
  rm -rf /home/*
  rm -f /root/build-on-vm.sh /tmp/build-on-vm.sh
  poweroff
}

case "${1:-}" in
  build) build ;;
  check) check ;;
  seal)  seal ;;
  *) echo "usage: sudo bash $0 build|check|seal" >&2; exit 2 ;;
esac
