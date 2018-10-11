#!/bin/bash -e
#
# Automatic reboot script
# Supported platforms: Ubuntu, Amazon Linux
# Requirements: awscli, jq, yum-utils (rhel)
#
_die() { echo >&2 "$@"; exit 1; }
_usage() { _die "usage: $0 [-s SECS] [-f] [-n] <topic-name or topic-arn>"; }
_meta() { curl -s "http://169.254.169.254/latest/meta-data/$1" || _die "Failed to fetch EC2 metadata $1"; }
_json() {
  local arg; local json=""; local args=(); local n=0
  for arg; do
    args=("${args[@]}" --arg k$n "${arg%%=*}" --arg v$n "${arg#*=}")
    json="${json:+"$json,"}(\$k$n):\$v$n"
    n=$((n + 1))
  done
  jq -n -c "${args[@]}" "{$json}"
}

REBOOT=no
DRYRUN=no
SLEEP=0
while getopts s:fn OPT; do
  case $OPT in
    s ) SLEEP=$OPTARG ;;
    f ) REBOOT=yes ;;
    n ) DRYRUN=yes ;;
    * ) _usage ;;
  esac
done
shift $((OPTIND - 1))

TOPIC="$1"
[[ -z "$TOPIC" ]] && _usage

# Check OS
. /etc/os-release
case $ID_LIKE in
  *debian* ) OS=debian ;;
  *centos* ) OS=centos ;;
  * ) _die "Unknown OS: $PRETTY_NAME" ;;
esac

# Check reboot
_checkreboot_debian() {
  echo "A reboot is required by following package(s):"
  cat /var/run/reboot-required.pkgs 2>/dev/null
  [[ -e /var/run/reboot-required ]]
}
_checkreboot_centos() {
  ! needs-restarting -r
}

if [[ $REBOOT = yes ]]; then
  REBOOTTEXT="Force reboot attempted by $0"
else
  REBOOTTEXT=$(_checkreboot_$OS)
  [[ $? = 0 ]] || exit
fi

AZ=$(_meta placement/availability-zone)
export AWS_DEFAULT_REGION=${AWS_DEFAULT_REGION:-${AZ%[a-z]}}
export AWS_DEFAULT_OUTPUT=text

if [[ "$TOPIC" != arn:aws:sns:* ]]; then
  TOPIC=$(aws sns list-topics --query "Topics[?ends_with(TopicArn,\`:${TOPIC}\`)].TopicArn")
  [[ -z "$TOPIC" ]] && _die "SNS topic $1 not found."
fi

((SLEEP > 0)) && sleep $((RANDOM % SLEEP))

HOSTNAME=$(hostname)
SUBJECT="[${HOSTNAME}] System reboot attempted"
[[ $DRYRUN = yes ]] && SUBJECT="[DRY-RUN] $SUBJECT"
JSON=$(_json \
  notificationSource=ec2 \
  hostname="$HOSTNAME" \
  instanceId="$(_meta instance-id)" \
  localIpv4="$(_meta local-ipv4)" \
  publicIpv4="$(_meta public-ipv4)" \
  availabilityZone="$AZ" \
  message="$REBOOTTEXT"
)
SNSJSON=$(_json email="$REBOOTTEXT" default="$JSON")

aws sns publish --topic-arn "$TOPIC" --subject "$SUBJECT" \
    --message "$SNSJSON" --message-structure json >/dev/null
[[ $DRYRUN = yes ]] || shutdown -r -f +5 "Automatic reboot attempted after 5 mins." 2>/dev/null
