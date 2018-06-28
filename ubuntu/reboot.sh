#!/bin/bash
#
# Automatic reboot script for Ubuntu
# Requirements: awscli, jq
#
_die() { echo >&2 "$@"; exit 1; }
_meta() { curl -s "http://169.254.169.254/latest/meta-data/$1"; }
_json() { env - "$@" jq -n -c 'env'; }

[ -z "$1" ] && _die "usage: $0 <topic-name or topic-arn>"
[ -e /var/run/reboot-required ] || exit

TOPIC="$1"
if [[ "$TOPIC" != arn:aws:sns:* ]]; then
  TOPIC="$(aws sns list-topics | jq -r ".Topics[].TopicArn|select(endswith(\":$TOPIC\"))")"
  [ -z "$TOPIC" ] && _die "SNS topic $1 not found."
fi

HOSTNAME=$(hostname)
SUBJECT="[${HOSTNAME}] System reboot attempted"
TEXT="\
A reboot is required by following package(s):
$(cat /var/run/reboot-required.pkgs 2>/dev/null)
"
JSON=$(_json \
  notificationSource=ec2 \
  hostname="$HOSTNAME" \
  instanceId="$(_meta instance-id)" \
  localIpv4="$(_meta local-ipv4)" \
  publicIpv4="$(_meta public-ipv4)" \
  availabilityZone="$(_meta placement/availability-zone)" \
  message="$TEXT"
)
SNSJSON=$(_json email="$TEXT" default="$JSON")

aws sns publish --topic-arn "$TOPIC" --subject "$SUBJECT" \
    --message "$SNSJSON" --message-structure json >/dev/null
shutdown -r +5
