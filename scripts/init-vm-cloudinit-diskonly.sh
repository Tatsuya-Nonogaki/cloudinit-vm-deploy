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

if [ ! -d /etc/cloud ]; then
    echo "ERROR: /etc/cloud missing; this VM does not seem to be made for cloud-init" >&2
    exit 1
fi

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

# Install DiskOnly cloud.cfg (embedded)
DST_CFG="/etc/cloud/cloud.cfg"

cat <<'CLOUD_DFLT' > "$DST_CFG"
# Disk-only cloud-init configuration
# Purpose: Minimal, safe cloud.cfg to be installed on a clone prior to
#          running the disk-only reapply flow (Phase‑2 DiskOnly + Phase‑3).
# Guiding principles:
#  - Avoid any user/SSH/hosts/network mutation.
#  - Disable SSH host key regeneration.
#  - Keep only the modules needed to read the seed and perform partition/filesystem/swap work.
#  - Modules are set to once-per-instance so a fresh instance-id will cause them to run.
#
# IMPORTANT:
#  - Backup the existing /etc/cloud/cloud* ; init-vm-cloudinit-diskonly.sh will do it for you.
#  - Do NOT include network/user/write_files changes in the seed (user-data) used for disk-only.
#  - Test on a non-production VM first.

users: []
disable_root: false

# Keep the usual mount defaults (unchanged)
mount_default_fields: [~, ~, 'auto', 'defaults,nofail,x-systemd.after=cloud-init-network.service,_netdev', '0', '2']

# Prevent cloud-init from removing/regenerating SSH host keys in disk-only flow
ssh_deletekeys: false
ssh_genkeytypes: []

# These settings goes to /etc/cloud/cloud.cfg.d/99-override.cfg instead.
# preserve_hostname: true
# manage_etc_hosts: false

# Minimal init-stage modules sufficient for reading the seed and performing disk ops.
# Note: keep seed_random/bootcmd so cloud-init can read the seed datasource correctly.
cloud_init_modules:
  - [seed_random, once-per-instance]
  - [bootcmd, once-per-instance]
  - [growpart, once-per-instance]
  - [resizefs, once-per-instance]
  - [disk_setup, once-per-instance]
  - [mounts, once-per-instance]
  - [ca_certs, once-per-instance]

# Allow runcmd so the seed's runcmd block can perform the resize/swap script.
cloud_config_modules:
  - [runcmd, once-per-instance]

# Minimal final modules: avoid package updates and other heavy actions.
cloud_final_modules:
  - [write_files_deferred, once-per-instance]
  - [final_message, once-per-instance]

system_info:
  distro: rhel
  network:
    renderers: ['sysconfig', 'eni', 'netplan', 'network-manager', 'networkd']
  paths:
    cloud_dir: /var/lib/cloud/
    templates_dir: /etc/cloud/templates/
  ssh_svcname: sshd
CLOUD_DFLT

chmod 644 "$DST_CFG" || true
echo "Installed diskonly cloud.cfg -> $DST_CFG"

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
