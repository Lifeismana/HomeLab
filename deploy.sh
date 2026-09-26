#!/bin/bash

set -e

if [ $EUID -ne 0 ]; then
    echo "This script must be run as root"
    exit 1
fi

echo "Deploying quadlets"

rsync -rt --delete --mkpath --force ./conf/ /etc/secc/

rsync -rt --delete --mkpath --force ./podman/ /etc/containers/systemd/secc/

echo "Deploying systemd units"

systemctl link /etc/secc/systemd/*

echo "Reloading systemd"

systemctl daemon-reload

for f in /etc/secc/systemd/* ; do
    if [ "$(systemctl show -p RefuseManualStart --value "$SERVICE")" = "yes" ]; then
        echo "Skipping $f because it is marked as RefuseManualStart"
        continue
    fi
    systemctl enable --now $f
done
