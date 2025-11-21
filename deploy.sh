#!/bin/bash

set -e

if [ $EUID -ne 0 ]; then
    echo "This script must be run as root"
    exit 1
fi

echo "Deploying quadlets"

rsync -rt --delete --mkpath --force ./conf/ /etc/secc/

rsync -rt --delete --mkpath --force ./podman/ /etc/containers/systemd/secc/

echo "Reloading systemd"

systemctl daemon-reload

