#!/bin/sh
DIR=/etc/ssl
SOURCE=https://s3.amazonaws.com/rds-downloads/rds-combined-ca-bundle.pem
mkdir -p $DIR
cd $DIR
wget -N -q $SOURCE
