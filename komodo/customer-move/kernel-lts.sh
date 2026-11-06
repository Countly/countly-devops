#!/bin/bash
# Move an Ubuntu 24.04 GCE host from the HWE GCP kernel (6.17 / 7.x) to the LTS GCP kernel (6.8).
#
# Why: MongoDB 8.x refuses Linux 6.19-7.0.13 by `uname -r` (SERVER-121912), Ubuntu's 7.0 GCP
# kernel reports 7.0.0, and the 26.10.2 / 27.0.0-rc Compose bundles do not set GLIBC_TUNABLES
# for mongod, so the bundle's MongoDB will not start on it. 6.8 stays below 6.19 and keeps
# security updates. Same steps as base-image/build-on-vm.sh (step 8).
#
# Run it FIRST in a customer move, while the legacy stack still runs from its original tree:
# a reboot restarts every container from the paths it was created with.
#
#   sudo bash kernel-lts.sh            install, purge, check grub, then ask before rebooting
#   sudo bash kernel-lts.sh --reboot   same, and reboot without asking
#
# After the reboot: `uname -r` is 6.8.*, the data disks are mounted, the stack is healthy.
set -euo pipefail
REBOOT="${1:-}"
export DEBIAN_FRONTEND=noninteractive

echo "== running kernel: $(uname -r)"
case "$(uname -r)" in 6.8.*) echo "already on 6.8, nothing to do"; exit 0 ;; esac

echo "== install the LTS GCP kernel (6.8)"
apt-get update -qq
apt-get install -y -qq linux-gcp-lts-24.04 >/dev/null
ls /boot/vmlinuz-6.8.* >/dev/null 2>&1 || { echo "STOP: no 6.8 kernel in /boot"; exit 1; }

echo "== purge the HWE metapackages and every 6.17-6.18 / 6.19+ / 7.x kernel package"
apt-get purge -y -qq linux-gcp linux-image-gcp linux-headers-gcp >/dev/null 2>&1 || true
# The running kernel is one of these: answer "don't abort" to linux-base's removal question.
echo 'linux-base linux-base/removing-running-kernel boolean false' | debconf-set-selections
hwe="$(dpkg-query -W -f '${Package}\n' 'linux-*' | grep -E -- '-(6\.(19|[2-9][0-9])|6\.1[7-8]|[7-9]\.[0-9]+)\.[0-9]+-[0-9]+(-gcp)?$|linux-gcp-(6\.1[7-9]|[7-9]\.[0-9]+)-' || true)"
echo "  purging $(echo $hwe | wc -w) packages"
[ -z "$hwe" ] || apt-get purge -y -qq $hwe >/dev/null

echo "== check what will boot"
ls /boot/vmlinuz-*
grep -m3 -oE "menuentry '[^']*'" /boot/grub/grub.cfg
if grep -qE 'vmlinuz-(6\.1[7-9]|6\.[2-9][0-9]|[7-9]\.)' /boot/grub/grub.cfg; then
  echo "STOP: grub.cfg still names a 6.17+/7.x kernel; run update-grub and check again"; exit 1
fi
if dpkg-query -W -f '${Status}\n' linux-image-gcp 2>/dev/null | grep -q '^install ok installed'; then
  echo "STOP: linux-image-gcp is still installed (it pulls 7.x kernels back)"; exit 1
fi

# A hard reset right after the purge loses the unwritten /boot and grub.cfg: GRUB then boots the
# deleted kernel, whose modules are gone, and the data mounts and Docker fail. Flush, then a clean
# reboot only (never `gcloud compute instances reset`).
sync

if [ "$REBOOT" != "--reboot" ]; then
  read -r -p "Reboot now (clean systemctl reboot)? [y/N] " a
  [ "$a" = y ] || { echo "Not rebooted. Run: sync && systemctl reboot"; exit 0; }
fi
echo "== clean reboot in 5 s"
( sleep 5; sync; systemctl reboot ) >/dev/null 2>&1 &
