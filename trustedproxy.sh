#!/bin/bash
#
# This script generates trusted proxy list from VPC subnets and CloudFront addresses.
# Supported output format:
# - Apache mod_remoteip
# - Nginx ngx_http_realip_module
# - Raw
#

die() { echo >&2 "$@"; exit 1; }
usage() { cat <<EOS >&2; exit 1; }
usage: $0 [-s SERVER] [-o FILENAME] [-r RELOADCMD] [-h]

options:
  -s SERVER             server type; apache, nginx, raw (default: apache)
  -o FILENAME           output filename
  -r RELOADCMD          invoke command on update
  -h                    show this help
EOS

# constants

UPTODATE=100
EC2META=http://169.254.169.254/latest/meta-data/network/interfaces/macs
IPRANGES=https://ip-ranges.amazonaws.com/ip-ranges.json
VPCBLOCKS=(
  vpc-ipv4-cidr-block
  vpc-ipv4-cidr-blocks
  vpc-ipv6-cidr-blocks
)
JQFILTERS=(
  '.prefixes[] | select(.service=="CLOUDFRONT") | .ip_prefix'
  '.ipv6_prefixes[] | select(.service=="CLOUDFRONT") | .ipv6_prefix'
)

# parse options

SERVER=apache
CONFOUT=
RELOADCMD=
while getopts s:o:r:h OPT; do
  case $OPT in
    s ) SERVER="$OPTARG" ;;
    o ) CONFOUT="$OPTARG" ;;
    r ) RELOADCMD="$OPTARG" ;;
    * ) usage ;;
  esac
done
shift $((OPTIND - 1))

case $SERVER in
  apache ) MKLINE='$1 {print "RemoteIPTrustedProxy " $1}' ;;
  nginx  ) MKLINE='$1 {print "set_real_ip_from " $1 ";"}' ;;
  raw    ) MKLINE='$1 {print $1}' ;;
  * ) echo >&2 "$0: Invalid server type: $SERVER"; usage ;;
esac

# check required commands: curl / jq

for cmd in curl jq; do
  type $cmd >/dev/null 2>&1 || die "$cmd required. please install."
done

# setup

CACHEDIR=/var/tmp/ipranges
IPJSON=$CACHEDIR/ip-ranges.json
IPMETA=$CACHEDIR/ip-ranges.meta

mkdir -p -m 700 $CACHEDIR
JSONTMP=$(mktemp -p $CACHEDIR)
METATMP=$(mktemp -p $CACHEDIR)
CONFTMP=$(mktemp)
trap 'rm -f $JSONTMP $CONFTMP $METATMP' EXIT

mapheader() {
  local VAR=$(grep -i "^$1:" | sed 's/[^:]*:[[:space:]]*//;s/[[:space:]]*$//')
  [[ -n "$VAR" ]] && CURLHEADER=("${CURLHEADER[@]}" -H "$2: $VAR")
}

# ip-ranges.json

CURLHEADER=()
IPCHANGED=yes
if [[ -f $IPJSON && -f $IPMETA ]]; then
  mapheader Last-Modified If-Modified-Since < $IPMETA
  mapheader ETag If-None-Match < $IPMETA
fi
curl -f -s $IPRANGES -o $JSONTMP -D $METATMP "${CURLHEADER[@]}" || die "Failed to get $IPRANGES"
grep '^HTTP/1.[[:digit:]] 304' $METATMP >/dev/null && IPCHANGED=no
if [[ $IPCHANGED = yes ]]; then
  mv $JSONTMP $IPJSON && mv $METATMP $IPMETA || die "Cannot write to $IPJSON"
fi
# exit if no change
[[ -f "$CONFOUT" && $IPCHANGED = no ]] && exit $UPTODATE

# generate config file

generate() {
  case $SERVER in
    apache )
      echo "RemoteIPHeader X-Forwarded-For"
      ;;
    nginx )
      echo "real_ip_header X-Forwarded-For;"
      echo "real_ip_recursive on;"
      ;;
  esac

  echo "# VPC subnets"
  curl -f -s $EC2META/ | awk '{print $0}' | \
  while read mac; do
    for block in ${VPCBLOCKS[*]}; do
      curl -f -s $EC2META/$mac$block | awk "$MKLINE"
    done
  done | sort | uniq

  echo "# CloudFront"
  for filter in "${JQFILTERS[@]}"; do
    jq -r "$filter" < $IPJSON | awk "$MKLINE" | sort
  done
}
generate > $CONFTMP

# output
[[ -z "$CONFOUT" ]] && { cat $CONFTMP; exit; }
diff $CONFOUT $CONFTMP >/dev/null 2>&1 && exit $UPTODATE

chmod 644 $CONFTMP
mv $CONFTMP $CONFOUT || die "Cannot write to $CONFOUT"
[[ -z "$RELOADCMD" ]] || sh -c "$RELOADCMD"
