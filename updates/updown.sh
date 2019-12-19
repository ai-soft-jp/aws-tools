#!/bin/bash -e
#
# System startup / shutdown report script
# Supported platforms: Ubuntu, Amazon Linux
# Requirements: awscli, jq, yum-utils (rhel)
#
META="http://169.254.169.254/latest"
_die() { echo >&2 "$@"; exit 1; }
_usage() { _die "usage: $0 <topic-name or topic-arn> <start or stop>"; }
_meta() {
  curl -sf --connect-timeout 3 "$META/meta-data/$1" -H "X-aws-ec2-metadata-token: $METATOKEN" || \
  _die "Failed to fetch EC2 metadata $1";
}
_json() {
  local arg; local json=""; local args=(); local n=0
  for arg; do
    args=("${args[@]}" --arg k$n "${arg%%=*}" --arg v$n "${arg#*=}")
    json="${json:+"$json,"}(\$k$n):\$v$n"
    n=$((n + 1))
  done
  jq -n -c "${args[@]}" "{$json}"
}

TOPIC="$1"
[[ -z "$TOPIC" ]] && _usage
ACTION="$2"
case $ACTION in
  start )
    SUBJECT="starting up"
    ;;
  stop )
    SUBJECT="shutting down"
    ;;
  * )
    _usage
    ;;
esac
MESSAGETEXT="\
$(uptime)
$(who -b -u -T)
"

METATOKEN=$(curl -s -X PUT "$META/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 60")
[[ -n "$METATOKEN" ]] || _die "Can't access instance meta-data."

AZ=$(_meta placement/availability-zone)
export AWS_DEFAULT_REGION=${AWS_DEFAULT_REGION:-${AZ%[a-z]}}
export AWS_DEFAULT_OUTPUT=text
export PATH="$PATH:/snap/bin"

if [[ "$TOPIC" != arn:aws:sns:* ]]; then
  TOPIC=$(aws sns list-topics --query "Topics[?ends_with(TopicArn,\`:${TOPIC}\`)].TopicArn")
  [[ -z "$TOPIC" ]] && _die "SNS topic $1 not found."
fi

HOSTNAME=$(hostname)
SUBJECT="[${HOSTNAME}] System $SUBJECT"
JSON=$(_json \
  notificationSource=ec2 \
  hostname="$HOSTNAME" \
  instanceId="$(_meta instance-id)" \
  localIpv4="$(_meta local-ipv4)" \
  publicIpv4="$(_meta public-ipv4)" \
  availabilityZone="$AZ" \
  message="$MESSAGETEXT"
)
SNSJSON=$(_json email="$MESSAGETEXT" default="$JSON")

aws sns publish --topic-arn "$TOPIC" --subject "$SUBJECT" \
    --message "$SNSJSON" --message-structure json >/dev/null
