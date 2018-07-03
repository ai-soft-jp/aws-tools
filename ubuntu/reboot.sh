#!/bin/bash
#
# Automatic reboot script for Ubuntu
# Requirements: awscli, jq
#
_die() { echo >&2 "$@"; exit 1; }
_usage() { _die "usage: $0 [-s SECS] [-f] [-n] <topic-name or topic-arn>"; }
_meta() { curl -s "http://169.254.169.254/latest/meta-data/$1"; }
_json() {
  local arg; local json=""; local args=(); local n=0
  for arg; do
    args=("${args[@]}" --arg k$n "${arg%%=*}" --arg v$n "${arg#*=}")
    json="${json:+"$json,"}(\$k$n):\$v$n"
    n=$((n + 1))
  done
  jq -n -c "${args[@]}" "{$json}"
}

FORCE=no
DRYRUN=no
SLEEP=0
while getopts s:fn OPT; do
  case $OPT in
    s ) SLEEP=$OPTARG ;;
    f ) FORCE=yes ;;
    n ) DRYRUN=yes ;;
    * ) _usage ;;
  esac
done
shift $((OPTIND - 1))

TOPIC="$1"
[[ -z "$TOPIC" ]] && _usage
[[ $FORCE = yes || -e /var/run/reboot-required ]] || exit

AZ=$(_meta placement/availability-zone)
export AWS_DEFAULT_REGION=${AWS_DEFAULT_REGION:-${AZ%[a-z]}}

if [[ "$TOPIC" != arn:aws:sns:* ]]; then
  TOPIC="$(aws sns list-topics | jq -r ".Topics[].TopicArn" | grep ":${TOPIC}\$" -m1)"
  [ -z "$TOPIC" ] && _die "SNS topic $1 not found."
fi

((SLEEP > 0)) && sleep $((RANDOM % SLEEP))

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
  availabilityZone="$AZ" \
  message="$TEXT"
)
SNSJSON=$(_json email="$TEXT" default="$JSON")

aws sns publish --topic-arn "$TOPIC" --subject "$SUBJECT" \
    --message "$SNSJSON" --message-structure json >/dev/null
[[ $DRYRUN = no ]] && shutdown -r -f +5 "Automatic reboot attempted after 5 mins."
