#!/bin/bash
#
# Nagios notification to slack
# Copyright Ai-SOFT Inc.
#
# Usage: notify_slack.sh {-e URI|-t TOKENS} [-n USERNAME] [-i ICONURL] [-c CHANNEL] [-H|-S] [VAR=VALUE...]
#
# Options:
#   -e URI          Slack incoming webhook URI
#   -t TOKEN...     Colon-separated webhook tokens
#   -n USERNAME     Username (default: "Nagios (hostname)")
#   -i ICONURL      Icon URL (default: use aispub)
#   -c CHANNEL      Slack channel (default: use default)
#   -H              Host notification
#   -S              Service notification (default)
#   VAR=VALUE       Nagios variables i.e. SERVICESTATE='$SERVICESTATE$'
#
# Note:
#   This script requires jq and curl.
#
_die() { echo >&2 "$@"; exit 1; }
_usage() { _die "usage: $0 {-e URI|-t TOKENS} [-n USERNAME] [-i ICONURL] [-c CHANNEL] [-H|-S] [VAR=VALUE...]"; }

WEBHOOK=
TOKENS=
USERNAME="Nagios ($(hostname -s))"
ICONURL=https://aispub.s3.amazonaws.com/svicons/nagios.png
CHANNEL=
MODE=service
while getopts e:t:n:i:c:HSh OPT; do
  case $OPT in
    e ) WEBHOOK=$OPTARG ;;
    t ) TOKENS=$OPTARG ;;
    n ) USERNAME=$OPTARG ;;
    i ) ICONURL=$OPTARG ;;
    c ) CHANNEL=$OPTARG ;;
    H ) MODE=host ;;
    S ) MODE=service ;;
    * ) _usage ;;
  esac
done
shift $((OPTIND - 1))
for var; do
  [[ $var = *=* ]] || _usage
  eval "NAGIOS_${var%%=*}"='${var#*=}'
done

WEBHOOKS=($WEBHOOK)
for token in ${TOKENS//:/ }; do
  WEBHOOKS+=("https://hooks.slack.com/services/$token")
done
[[ ${#WEBHOOKS[*]} = 0 ]] && _usage
[[ -z $NAGIOS_NOTIFICATIONTYPE ]] && _die "No Nagios variables."

EOL=$'\n'

ARGN=1; JQARGS=(); JQSTMPL=; JQATMPL=; JQREPL=
_jqarg() {
  local k=${1%%=*}; local v=${1#*=}
  JQARGS=("${JQARGS[@]}" --arg k$ARGN "$k" --arg v$ARGN "$v")
  JQREPL="(\$k$ARGN):\$v$ARGN"
  ARGN=$((ARGN + 1))
}
_slack() { _jqarg "$1"; JQSTMPL="${JQSTMPL:+$JQSTMPL,}$JQREPL"; }
_attach() { _jqarg "$1"; JQATMPL="${JQATMPL:+$JQATMPL,}$JQREPL"; }

_slack username="$USERNAME"
[[ -n $ICONURL ]] && _slack icon_url="$ICONURL"
[[ -n $CHANNEL ]] && _slack channel="$CHANNEL"

case $MODE in
  service )
    STATE=$NAGIOS_SERVICESTATE
    NAME="${NAGIOS_HOSTALIAS:-$NAGIOS_HOSTNAME}/$NAGIOS_SERVICEDESC"
    OUT=$(echo -e "$NAGIOS_SERVICEOUTPUT")
    LONGOUT=$(echo -e "$NAGIOS_LONGSERVICEOUTPUT")
    ;;
  host )
    STATE=$NAGIOS_HOSTSTATE
    NAME="Host ${NAGIOS_HOSTDISPLAYNAME:-$NAGIOS_HOSTNAME}"
    OUT=$(echo -e "$NAGIOS_HOSTOUTPUT")
    LONGOUT=$(echo -e "$NAGIOS_LONGHOSTOUTPUT")
    ;;
esac
NTYPE=$NAGIOS_NOTIFICATIONTYPE
FALLBACK="$NTYPE - $NAME is $STATE"
TEXT="*$STATE*: $NAME"
OUT="$OUT${LONGOUT:+$EOL$LONGOUT}"
COLOR=
case $NTYPE in
  PROBLEM           ) NTYPE=;;
  RECOVERY          ) NTYPE=; COLOR="good";;
  ACKNOWLEDGEMENT   ) COLOR="#888";;
  FLAPPINGSTART     ) COLOR="warning";;
  FLAPPINGSTOP      ) COLOR="good";;
  FLAPPINGDISABLED  ) COLOR="#888";;
  DOWNTIMESTART     ) COLOR="#ffd700";;
  DOWNTIMEEND       ) COLOR="good";;
  DOWNTIMECANCELLED ) COLOR="good";;
esac
if [[ -z $COLOR ]]; then
  case $STATE in
    OK | UP           ) COLOR="good";;
    WARNING | UNKNOWN ) COLOR="warning";;
    CRITICAL | DOWN   ) COLOR="danger";;
  esac
fi
[[ $COLOR = good ]] || TEXT="$TEXT$EOL$OUT"
_attach fallback="$FALLBACK"
_attach text="${NTYPE:+"$NTYPE - "}$TEXT"
[[ -n "$COLOR" ]] && _attach color="$COLOR"

JSON=$(jq -n -c "${JQARGS[@]}" "{$JQSTMPL,\"attachments\":[{$JQATMPL}]}")

for uri in "${WEBHOOKS[@]}"; do
  curl -f -s "$uri" -d "$JSON" -H 'Content-Type: application/json' >/dev/null &
done
wait
