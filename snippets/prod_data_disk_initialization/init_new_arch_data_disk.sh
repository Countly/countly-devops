#!/usr/bin/env bash
# =============================================================================
# init-disks.sh — Data Disk Initializer for Countly GCP Instances
# =============================================================================
#
# WHAT THIS SCRIPT DOES:
#   On a brand-new GCP instance, the extra data disks (MongoDB, ClickHouse,
#   Kafka) are attached but completely raw — no filesystem, no mount point.
#   This script formats each disk with XFS, mounts it at the right folder,
#   and records it in /etc/fstab so the mount survives reboots.
#
# WHEN TO RUN:
#   Once only, during first-time instance setup (e.g. from cloud-init or
#   your provisioning script). Running it again on an already-initialized
#   instance is safe — it detects existing filesystems and skips formatting.
#
# HOW TO RUN:
#   sudo bash init-disks.sh
#
# PRE-REQUISITE (IMPORTANT):
#   The GCP instance must be created with a fixed "device name" for each
#   data disk. In your Node.js deployment code, add deviceName to each disk:
#
#     { initializeParams: { diskName: `${instanceName}-mongodb-disk`, ... },
#       deviceName: 'mongodb-data', ... }
#
#   Without this, the stable symlinks this script relies on won't exist.
#
# AFTER A DISK IS RESTORED FROM SNAPSHOT (DR):
#   1. Detach old disk from instance (GCP Console → VM → Edit)
#   2. Attach new disk created from snapshot — set Device name to e.g. "mongodb-data"
#   3. SSH into instance and run: mount -a
#   The restored disk is automatically mounted at the correct path. No need
#   to re-run this script.
#
# =============================================================================

set -euo pipefail
# set -e  → exit immediately if any command fails
# set -u  → treat unset variables as errors
# set -o pipefail → if any command in a pipe fails, the whole pipe fails

# -----------------------------------------------------------------------------
# CONFIGURATION
# -----------------------------------------------------------------------------

# Maps each GCP disk (identified by its stable device-name symlink) to the
# folder it should be mounted at inside the instance.
#
# Why use /dev/disk/by-id/google-* instead of /dev/sdb, /dev/sdc, etc.?
# GCP does not guarantee which /dev/sdX letter a disk gets — it depends on
# attachment order and can change. The google-* symlinks are stable: they
# always point to the correct disk regardless of the sdX letter assigned.
declare -A DISKS=(
  ["/dev/disk/by-id/google-mongodb-data"]="/mongodb-data"
  ["/dev/disk/by-id/google-clickhouse-data"]="/clickhouse-data"
  ["/dev/disk/by-id/google-kafka-data"]="/kafka-data"
)

# Filesystem type. XFS is chosen for its performance with large databases
# and its ability to be mounted read-write on a live system.
FS_TYPE="xfs"

# Mount options written into /etc/fstab:
#   defaults    — standard read/write mount with sensible defaults
#   noatime     — don't update file access timestamps on every read
#                 (reduces unnecessary disk writes, improves performance)
#   nofail      — if this disk is missing at boot, the instance still starts
#                 normally instead of dropping into emergency shell
MOUNT_OPTS="defaults,noatime,nofail"

# Directories that need explicit ownership set before the container starts.
#
# Kafka (apache/kafka image) runs as user "appuser" (uid 1000, gid 1000) and
# requires the data directory to be owned by that user before it starts.
# If the directory is owned by root, Kafka will fail to write and crash.
#
# MongoDB and ClickHouse are NOT listed here because their Docker images
# automatically fix ownership of the data directory on first startup.
declare -A OWNERSHIP=(
  ["/kafka-data"]="1000:1000"
)

# -----------------------------------------------------------------------------
# HELPER FUNCTIONS
# -----------------------------------------------------------------------------

# log: prints a timestamped message to stdout for easy progress tracking
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

# die: prints an error message to stderr and exits the script immediately
die() { echo "[ERROR] $*" >&2; exit 1; }

# Ensure the script is running as root (required for mkfs, mount, chown, fstab)
[[ $EUID -eq 0 ]] || die "This script must be run as root. Try: sudo bash init-disks.sh"

# -----------------------------------------------------------------------------
# FUNCTION: format_and_mount
# -----------------------------------------------------------------------------
# Prepares a single disk and mounts it at the given folder.
#
# Arguments:
#   $1 — device path (e.g. /dev/disk/by-id/google-mongodb-data)
#   $2 — mount point  (e.g. /mongodb-data)
#
# Returns:
#   0 — disk was freshly formatted and mounted (ownership will be set)
#   1 — disk was already mounted, nothing changed (ownership will be skipped)
#
# Steps performed:
#   1. Verify the block device actually exists
#   2. Skip entirely if already mounted (safe to re-run)
#   3. Format with XFS only if no filesystem exists yet
#      — aborts if a different filesystem is found (protects existing data)
#   4. Create the mount point directory if it doesn't exist
#   5. Read the disk's UUID and add a fstab entry (if not already there)
#      — fstab uses UUID (not /dev/sdX) so mounts survive disk reattachment
#   6. Mount the disk
# -----------------------------------------------------------------------------
format_and_mount() {
  local device="$1" mountpoint="$2"

  # Verify the device exists as a block device
  [[ -b "$device" ]] || die "Block device $device not found. Check that deviceName is set correctly in your GCP instance creation code."

  # If already mounted, nothing to do — skip silently
  if mountpoint -q "$mountpoint"; then
    log "$mountpoint already mounted. Skipping."
    return 1
  fi

  # Check if the disk already has a filesystem on it
  local existing_fs
  existing_fs=$(blkid -o value -s TYPE "$device" 2>/dev/null || true)

  if [[ -z "$existing_fs" ]]; then
    # No filesystem found — safe to format
    log "No filesystem on $device. Creating $FS_TYPE..."
    mkfs."$FS_TYPE" -f "$device"
  elif [[ "$existing_fs" != "$FS_TYPE" ]]; then
    # Unexpected filesystem type — abort rather than risk wiping existing data
    die "$device already has a '$existing_fs' filesystem (expected $FS_TYPE). Aborting to avoid data loss. Detach this disk and check manually."
  else
    # Already formatted with the correct filesystem — reuse it
    log "$device already has $FS_TYPE filesystem. Reusing."
  fi

  # Create the mount point folder if it doesn't exist
  mkdir -p "$mountpoint"

  # Read the disk's UUID — a permanent identifier baked into the filesystem.
  # fstab entries use UUID instead of /dev/sdX because:
  #   - /dev/sdX letters can change when disks are reattached
  #   - UUID stays the same even after detach/reattach or snapshot restore
  local uuid
  uuid=$(blkid -o value -s UUID "$device")
  [[ -n "$uuid" ]] || die "Could not read UUID from $device. The disk may not have been formatted correctly."

  # Add fstab entry only if this UUID isn't already recorded
  # fstab is what makes the mount persist across reboots
  if ! grep -q "UUID=${uuid}" /etc/fstab; then
    # Fields: UUID  mountpoint  filesystem  options  dump  fsck-pass
    # dump=0:      disable legacy dump backups (not used)
    # fsck-pass=0: skip fsck at boot — XFS uses its own journal replay
    echo "UUID=${uuid} ${mountpoint} ${FS_TYPE} ${MOUNT_OPTS} 0 0" >> /etc/fstab
    log "Added $mountpoint to /etc/fstab."
  fi

  # Mount the disk now (fstab will handle future reboots automatically)
  mount "$mountpoint"
  log "Mounted $device at $mountpoint."
  return 0
}

# -----------------------------------------------------------------------------
# FUNCTION: set_ownership
# -----------------------------------------------------------------------------
# Sets directory ownership for mount points that require it.
# Only called on freshly mounted disks — never on already-mounted ones.
#
# Arguments:
#   $1 — mount point (e.g. /kafka-data)
#
# If the mount point is listed in the OWNERSHIP map, chown is applied.
# If not listed, this function does nothing.
# -----------------------------------------------------------------------------
set_ownership() {
  local mountpoint="$1" owner="${OWNERSHIP[$1]:-}"
  if [[ -n "$owner" ]]; then
    chown "$owner" "$mountpoint"
    log "Set ownership of $mountpoint to $owner."
  fi
}

# -----------------------------------------------------------------------------
# FUNCTION: verify_mounts
# -----------------------------------------------------------------------------
# Runs after all disks are processed to confirm every expected mount point
# is actually mounted. Prints disk size and free space for each.
# Exits with an error if any mount is missing.
# -----------------------------------------------------------------------------
verify_mounts() {
  local failed=0
  for device in "${!DISKS[@]}"; do
    local mp="${DISKS[$device]}"
    if mountpoint -q "$mp"; then
      log "OK: $mp is mounted ($(df -h "$mp" | awk 'NR==2{print $2" total, "$4" free"}'))."
    else
      log "FAIL: $mp is NOT mounted!"
      failed=1
    fi
  done
  [[ $failed -eq 0 ]] || die "One or more mounts failed. Check the logs above for details."
}

# -----------------------------------------------------------------------------
# MAIN
# -----------------------------------------------------------------------------
# Iterates over each disk, formats and mounts it, then sets ownership if
# needed. Finishes with a verification pass and a daemon-reload so systemd
# picks up the new fstab entries.
# -----------------------------------------------------------------------------
main() {
  for device in "${!DISKS[@]}"; do
    local mountpoint="${DISKS[$device]}"
    log "Processing $device -> $mountpoint"
    if format_and_mount "$device" "$mountpoint"; then
      set_ownership "$mountpoint"
    fi
  done

  # Tell systemd to re-read unit files — picks up any new fstab-generated
  # mount units without requiring a reboot
  systemctl daemon-reload

  verify_mounts
  log "All data disks initialized successfully."
}

main "$@"
