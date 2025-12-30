#!/bin/sh -x
# Prevents this system from accidental cloud-init initialization.
# This script must be run with root privileges, otherwise no effect.
CWD=$(dirname $0)
if [ ! -d /etc/cloud ]; then
    echo error && exit 1
fi
install -m 644 /dev/null /etc/cloud/cloud-init.disabled
install -m 644 $CWD/cloud.cfg /etc/cloud
install -m 644 $CWD/99-template-maint.cfg /etc/cloud/cloud.cfg.d

