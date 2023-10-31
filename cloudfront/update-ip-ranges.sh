#!/bin/bash
#
# This script generates trusted proxy list from VPC subnets and CloudFront addresses.
# Supported output format:
# - Apache mod_remoteip / mod_authz_core (mod_authz_host for 2.2)
# - Nginx ngx_http_realip_module / ngx_http_access_module
#

_die() { echo >&2 "$@"; exit 1; }
_usage() { cat <<EOS >&2; exit 1; }
usage: $0 [-s SERVER] [-o FILENAME] [-r RELOADCMD] [-h]

options:
  -s SERVER             server type; apache2.2, apache[2.4], nginx (default: apache2.4)
  -4                    IPv4 only (default: include IPv6)
  -o FILENAME           output filename for proxy list
  -a FILENAME           output filename for access list
  -r RELOADCMD          invoke command on update
  -f                    force to regenerate
  -v                    enable debug output
  -h                    show this help
EOS

# check required commands: curl / jq

for cmd in curl jq; do
  type $cmd >/dev/null 2>&1 || _die "$cmd required. please install."
done

# constants

EC2META=http://169.254.169.254/latest
MACSMETA=$EC2META/meta-data/network/interfaces/macs
IPRANGES=https://ip-ranges.amazonaws.com/ip-ranges.json
VPCBLOCKS4=( vpc-ipv4-cidr-block vpc-ipv4-cidr-blocks )
VPCBLOCKS6=( vpc-ipv6-cidr-blocks )
JQFILTER4='.prefixes[] | select(.service=="CLOUDFRONT") | .ip_prefix'
JQFILTER6='.ipv6_prefixes[] | select(.service=="CLOUDFRONT") | .ipv6_prefix'

# parse options

SERVER=apache
MODE=proxy
IPVER=6
PROXYOUT=
ACCESOUT=
FORCE=no
VERBOSE=no
RELOADCMD=
while getopts s:o:a:r:h4fv OPT; do
  case $OPT in
    s ) SERVER="$OPTARG" ;;
    4 ) IPVER=4 ;;
    o ) PROXYOUT="$OPTARG" ;;
    a ) ACCESOUT="$OPTARG" ;;
    f ) FORCE=yes ;;
    v ) VERBOSE=yes ;;
    r ) RELOADCMD="$OPTARG" ;;
    * ) _usage ;;
  esac
done
shift $((OPTIND - 1))

if [[ $VERBOSE = yes ]]; then
  _debug() { echo >&2 DEBUG: "$@"; }
else
  _debug() { :; }
fi

case $SERVER in
  apache | apache24 | apache2.4 )
    _debug "server is Apache 2.4"
    PROXYHDR=$'RemoteIPHeader X-Forwarded-For'
    MKPROXY='{print "RemoteIPTrustedProxy " $1}'
    MKACCES='{print "Require ip " $1}'
    ;;
  apache22 | apache2.2 )
    _debug "server is Apache 2.2"
    PROXYHDR=$'RemoteIPHeader X-Forwarded-For'
    MKPROXY='{print "RemoteIPTrustedProxy " $1}'
    MKACCES='{print "Allow from " $1}'
    ;;
  nginx )
    _debug "server is nginx"
    PROXYHDR=$'real_ip_header X-Forwarded-For;\nreal_ip_recursive on;'
    MKPROXY='{print "set_real_ip_from " $1 ";"}'
    MKACCES='{print "allow " $1 ";"}'
    ;;
  * )
    echo >&2 "$0: Invalid server/mode: $SERVERMODE"
    _usage
    ;;
esac
case $IPVER in
  6 )
    _debug "IP versions: IPv4 and IPv6"
    VPCBLOCKS=("${VPCBLOCKS4[@]}" "${VPCBLOCKS6[@]}")
    JQFILTERS=("$JQFILTER4" "$JQFILTER6")
    ;;
  4 )
    _debug "IP version: IPv4 only"
    VPCBLOCKS=("${VPCBLOCKS4[@]}")
    JQFILTERS=("$JQFILTER4")
    ;;
esac

# setup

CACHEDIR=/var/tmp/cloudfront-ip-ranges
IPJSON=$CACHEDIR/ip-ranges.json
IPMETA=$CACHEDIR/ip-ranges.meta
IPLIST=$CACHEDIR/ip-list.txt

mkdir -p -m 700 $CACHEDIR
JSONTMP=$(mktemp -p $CACHEDIR)
METATMP=$(mktemp -p $CACHEDIR)
LISTTMP=$(mktemp -p $CACHEDIR)
CONFTMP=$(mktemp)
trap 'rm -f $JSONTMP $METATMP $LISTTMP $CONFTMP' EXIT

CURL=$(which curl)
TOKEN=$($CURL -f -s -XPUT $EC2META/api/token -H'X-aws-ec2-metadata-token-ttl-seconds: 21600')
curl() { $CURL -H"X-aws-ec2-metadata-token: $TOKEN" "$@"; }
curl -f -s $EC2META/meta-data/instance-id >/dev/null || _die "Failed to get EC2 metadata"

_mapheader() {
  local VAR=$(grep -i "^$1:" | sed 's/[^:]*:[[:space:]]*//;s/[[:space:]]*$//')
  [[ -n "$VAR" ]] && CURLHEADER=("${CURLHEADER[@]}" -H "$2: $VAR")
}

# ip-ranges.json

CURLHEADER=()
IPCHANGED=yes
if [[ $FORCE = no && -f $IPJSON && -f $IPMETA ]]; then
  _mapheader Last-Modified If-Modified-Since < $IPMETA
  _mapheader ETag If-None-Match < $IPMETA
fi
_debug "fetch: $IPRANGES (${CURLHEADER[*]})"
curl -f -s $IPRANGES -o $JSONTMP -D $METATMP "${CURLHEADER[@]}" || _die "Failed to get $IPRANGES"
grep '^HTTP/1.[[:digit:]] 304' $METATMP >/dev/null && IPCHANGED=no
if [[ $IPCHANGED = yes ]]; then
  _debug "ip-ranges.json changed"
  mv $JSONTMP $IPJSON && mv $METATMP $IPMETA || _die "Cannot write to $IPJSON"
fi

# exit if no change
_checkupdate() {
  [[ $FORCE = yes ]] && return
  [[ $IPCHANGED = yes ]] && return
  [[ -f $IPLIST ]] || return
  [[ -n "$PROXYOUT" && ! -f "$PROXYOUT" ]] && return
  [[ -n "$ACCESOUT" && ! -f "$ACCESOUT" ]] && return
  _debug "all config files are up to date"
  exit
}
_checkupdate

# generate ip list

_genlist() {
  _debug "generating from VPC blocks"
  curl -f -s $MACSMETA/ | awk '{print $0}' | \
  while read mac; do
    for block in "${VPCBLOCKS[@]}"; do
      curl -f -s $MACSMETA/$mac$block | awk '$1 {print $1}'
    done
  done | sort | uniq

  _debug "generating from ip-ranges.json"
  for filter in "${JQFILTERS[@]}"; do
    jq -r "$filter" < $IPJSON | awk '$1 {print $1}' | sort
  done
}
_genlist > $LISTTMP
mv $LISTTMP $IPLIST || _die "Cannot write to $IPLIST"

# output configs

UPDATED=no
_genconf() {
  local MKLINE="$1" CONFOUT="$2" HEADER="$3"
  _debug "generating $CONFOUT"
  { echo -n "${HEADER:+"$HEADER"$'\n'}"; awk "$MKLINE" < $IPLIST; } > $CONFTMP
  [[ $FORCE = no ]] && diff "$CONFOUT" $CONFTMP >/dev/null 2>&1 && return
  chmod 0644 $CONFTMP
  mv $CONFTMP "$CONFOUT" || _die "Cannot write to $CONFOUT"
  UPDATED=yes
}

[[ -n "$PROXYOUT" ]] && _genconf "$MKPROXY" "$PROXYOUT" "$PROXYHDR"
[[ -n "$ACCESOUT" ]] && _genconf "$MKACCES" "$ACCESOUT"

[[ $UPDATED = no ]] && exit
if [[ -n "$RELOADCMD" ]]; then
  _debug "executing reload command"
  sh -c "$RELOADCMD"
fi
