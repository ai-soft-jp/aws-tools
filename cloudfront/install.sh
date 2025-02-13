#!/bin/bash
ln -s /opt/aws-tools/cloudfront/update-ip-ranges.timer /etc/systemd/system
ln -s /opt/aws-tools/cloudfront/update-ip-ranges.service /etc/systemd/system
systemctl daemon-reload
systemctl start update-ip-ranges.timer
systemctl enable update-ip-ranges.timer
