#!/bin/sh -x
# Prepare this system for disk-only cloud-init reapplication.
# This script must be run with root privileges, otherwise no effect.
CWD=$(dirname $0)
if [ ! -d /etc/cloud ]; then
    echo error && exit 1
fi
install -m 644 $CWD/cloud_diskonly.cfg /etc/cloud/cloud.cfg

