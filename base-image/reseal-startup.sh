#!/bin/bash
# reseal-startup.sh -- one-shot GCE startup-script for the already-sealed komodo-base-build.
# The first seal removed /home but left the login accounts, so nobody can SSH in. This runs as
# root at boot without SSH, applies the corrected seal (accounts removed too) and powers off.
# Remove the startup-script metadata afterwards; it never ends up in the image.
set -u
[ "$(hostname -s)" = komodo-base-build ] || { echo "reseal: not komodo-base-build, doing nothing"; exit 0; }

for u in $(awk -F: '$3>=1000 && $3<60000 {print $1}' /etc/passwd); do
  echo "reseal: removing account $u"
  userdel -f -r "$u" 2>/dev/null || userdel -f "$u"
done
rm -rf /home/*
rm -f /root/build-on-vm.sh /tmp/build-on-vm.sh
# root's leftovers (same list as clean_root in build-on-vm.sh): the 2026-09-18 backups of the
# legacy tree hold ssl/privkey.pem; gcloud's credential DBs; editor and shell history.
rm -rf /root/opt-countly-backup-* /root/*.tar /root/*.tar.gz /root/*.tgz \
       /root/.config/gcloud /root/.cache /root/.local /root/snap \
       /root/.viminfo /root/.lesshst /root/.bash_history /root/.wget-hsts /root/.python_history \
       /root/.ssh/authorized_keys
echo "reseal: /root now: $(ls -A /root | tr '\n' ' ')"

cloud-init clean --logs || true
truncate -s 0 /etc/machine-id
rm -f /var/lib/dbus/machine-id
rm -f /etc/ssh/ssh_host_*
journalctl --rotate && journalctl --vacuum-time=1s
rm -rf /tmp/* /var/tmp/* /root/.bash_history
echo "reseal: done, powering off"
poweroff
