#!/bin/sh -eux
#
# Minimal disk-only initialization for cloudinit-vm-deploy kit
# - Does NOT run `cloud-init clean` or truncate /etc/machine-id
# - Creates a compressed tarball backup of cloud-init related state into a timestamped backup dir
# - Removes /etc/cloud/cloud-init.disabled so Phase-3 seed can be applied
# - Replaces /etc/cloud/cloud.cfg.d/99-override.cfg
#
# Usage: copied to the guest and executed by Phase-2 via Invoke-VMScript / Copy-VMGuestFile
# This script must be run with root privileges, otherwise no effect.
#

# Timestamped backup directory
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP_DIR="/root/cloudinit-backup-$TIMESTAMP"
ARCHIVE="${BACKUP_DIR}/cloudinit-backup-${TIMESTAMP}.tgz"

mkdir -p "${BACKUP_DIR}"
chmod 700 "${BACKUP_DIR}"

# Collect list of items to archive (only include existing paths)
PATHS_TO_ARCHIVE=""
add_path_if_exists() {
  if [ -e "$1" ]; then
    # strip leading slash because we'll tar with -C /
    PATHS_TO_ARCHIVE="${PATHS_TO_ARCHIVE} ${1#/}"
  fi
}

add_path_if_exists "/var/lib/cloud"
add_path_if_exists "/var/log/cloud-init.log"
add_path_if_exists "/var/log/cloud-init-output.log"
add_path_if_exists "/etc/cloud/cloud-init.disabled"
add_path_if_exists "/etc/cloud/cloud.cfg"
add_path_if_exists "/etc/cloud/cloud.cfg.d"
add_path_if_exists "/etc/machine-id"

if [ -z "${PATHS_TO_ARCHIVE}" ]; then
  echo "No cloud-init-related files found to backup; creating empty marker in ${BACKUP_DIR}"
  touch "${BACKUP_DIR}/no-cloudinit-files-found"
else
  # Create compressed tarball from root (preserve relative paths)
  tar -C / -czf "$ARCHIVE" ${PATHS_TO_ARCHIVE} || TAR_EXIT=$?
  : ${TAR_EXIT:=0}
  if [ "${TAR_EXIT}" -ne 0 ]; then
    echo "Warning: tar exited with ${TAR_EXIT}. Archive may be incomplete." >&2
  else
    chmod 600 "$ARCHIVE"
    echo "Backup archive created: $ARCHIVE"
  fi
fi

# Optional: list the backup dir contents for operator convenience
ls -la "${BACKUP_DIR}" || true

# Remove cloud-init disabled marker to allow seed application in Phase-3
if [ -f /etc/cloud/cloud-init.disabled ]; then
  rm -f /etc/cloud/cloud-init.disabled
  echo "Removed /etc/cloud/cloud-init.disabled"
else
  echo "/etc/cloud/cloud-init.disabled not present; nothing to remove."
fi

OVR="/etc/cloud/cloud.cfg.d/99-override.cfg"

# Remove override config
if [ -f "$OVR" ]; then
  rm -f "$OVR"
  echo "Removed $OVR"
else
  echo "'$OVR' not present; nothing to remove."
fi

# Re-create override config
cat <<EOM >$OVR
preserve_hostname: true
manage_etc_hosts: false
ssh_deletekeys: false
ssh_genkeytypes: []
EOM
echo "Created $OVR"

exit 0
