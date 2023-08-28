#!/bin/sh
find /home/*/.cache/yarn/v6 -mindepth 1 -maxdepth 1 -mtime +7 -exec rm -rf '{}' '+'
rm -rf /tmp/yarn--*
