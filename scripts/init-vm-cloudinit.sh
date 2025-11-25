#!/bin/sh -x
subscription-manager clean
subscription-manager remove --all
nmcli -t -f UUID,TYPE connection show 2>/dev/null | awk -F: '$2=="802-3-ethernet" { print $1 }' | while read UUID; do
  [ -n "$UUID" ] && nmcli connection delete uuid "$UUID" >/dev/null 2>&1
done
nmcli connection reload >/dev/null 2>&1
cloud-init clean
truncate -s0 /etc/machine-id
rm -f /etc/cloud/cloud.cfg.d/99-template-maint.cfg /etc/cloud/cloud-init.disabled
# Create /etc/cloud/cloud.cfg.d/99-override.cfg for the clone
cat <<EOM >/etc/cloud/cloud.cfg.d/99-override.cfg
preserve_hostname: false
manage_etc_hosts: false
EOM

