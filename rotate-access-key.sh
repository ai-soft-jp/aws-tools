#!/bin/bash
#
export PATH=/usr/sbin:/usr/bin:/sbin:/bin/:/snap/bin
export LANG=C

_die() { echo >&2 "$@"; exit 1; }
_usage() { _die "usage: $0 [-v] [-h] [-t DAYS] [profile...]"; }
_check() { local status="$1"; (( $status == 0 )) || { shift; _die "$@"; } }
_log() { :; }
type aws >/dev/null 2>&1 || _die "aws: Command not found."

# defaults
DAYS=14
: ${AWS_SHARED_CREDENTIALS_FILE:=~/.aws/credentials}
: ${AWS_CONFIG_FILE:=~/.aws/config}

# process options
while getopts c:t:vh OPTNAME; do
  case $OPTNAME in
    t ) DAYS="$OPTARG" ;;
    v ) _log() { echo >&2 "$@"; } ;;
    h ) _usage ;;
    * ) _usage ;;
  esac
  shift $((OPTIND - 1))
done

# check errors
(( $DAYS > 0 )) >/dev/null 2>&1 || _die "Rotation days must be positive: $DAYS"
[[ -e "$AWS_CONFIG_FILE" ]] || _die "$AWS_SHARED_CREDENTIALS_FILE: No such file or directory."
[[ -e "$AWS_SHARED_CREDENTIALS_FILE" ]] || _die "$AWS_SHARED_CREDENTIALS_FILE: No such file or directory."

# environs
export AWS_CONFIG_FILE
export AWS_SHARED_CREDENTIALS_FILE
export AWS_DEFAULT_OUTPUT=text
unset AWS_ACCESS_KEY_ID
unset AWS_SECRET_ACCESS_KEY
unset AWS_SESSION_TOKEN

# profiles
PROFILES=("$@")
[[ -z "${PROFILES[@]}" ]] && PROFILES=("$AWS_DEFAULT_PROFILE")
[[ -z "${PROFILES[@]}" ]] && PROFILES=(default)

# preparation
ROTATE_THR=$(date '+%s' -d "$DAYS days ago")
BACKEDUP=""

# loop
ROTATED=0
for profile in "${PROFILES[@]}"; do
  [[ -z "$profile" ]] && continue
  export AWS_DEFAULT_PROFILE="$profile"
  _log "Processing profile $profile."

  ACCESS_KEY=$(aws configure get aws_access_key_id 2>/dev/null)
  [[ -z "$ACCESS_KEY" ]] && { _log ">> Access Key: Not Found; Skip."; continue; }
  _log ">> Access Key: $ACCESS_KEY"

  LAST_ROTATE=$(aws configure get last_rotate_time 2>/dev/null)
  if [[ -n "$LAST_ROTATE" ]]; then
    _log -n ">> Last rotate: $LAST_ROTATE: "
    LAST_ROTATE_EPOCH=$(date '+%s' -d "$LAST_ROTATE")
    (( $LAST_ROTATE_EPOCH > $ROTATE_THR )) && { _log "Not expired; Skip."; continue; }
    _log "Expired; Rotateion needed."
  else
    _log ">> Last rotate: Not Found; Rotation needed."
  fi

  UNUSED_KEYS=$(aws iam list-access-keys \
    --query "AccessKeyMetadata[?AccessKeyId!=\`\"$ACCESS_KEY\"\`].AccessKeyId")
  _check $? "Failed to list access keys."
  for key in $UNUSED_KEYS; do
    aws iam delete-access-key --access-key-id "$key"
    _check $? "Failed to delete access key."
    _log ">> Deleted expired key: $key"
  done

  NEW_KEY=$(aws iam create-access-key \
    --query 'AccessKey.[AccessKeyId,SecretAccessKey,CreateDate]')
  _check $? "Failed to create access key."
  NEW_ACCESS_KEY=$(echo "$NEW_KEY" | awk '{print $1}')
  NEW_SECRET_KEY=$(echo "$NEW_KEY" | awk '{print $2}')
  NEW_CREATE_DATE=$(echo "$NEW_KEY" | awk '{print $3}')
  _log ">> New Access Key: $NEW_ACCESS_KEY"

  if [[ -z "$BACKEDUP" ]]; then
    rm -f "${AWS_SHARED_CREDENTIALS_FILE}.bak" "${AWS_CONFIG_FILE}.bak"
    cp -p "$AWS_SHARED_CREDENTIALS_FILE" "${AWS_SHARED_CREDENTIALS_FILE}.bak"
    cp -p "$AWS_CONFIG_FILE" "${AWS_CONFIG_FILE}.bak"
    _log "!!! Backup created: ${AWS_CONFIG_FILE}.bak, ${AWS_SHARED_CREDENTIALS_FILE}.bak"
    BACKEDUP=true
  fi

  aws configure set aws_access_key_id "$NEW_ACCESS_KEY"
  aws configure set aws_secret_access_key "$NEW_SECRET_KEY"
  aws configure set last_rotate_time "$NEW_CREATE_DATE"
  while :; do
    sleep 1
    OUT=$(aws iam update-access-key --access-key-id "$ACCESS_KEY" --status Inactive 2>&1)
    STATUS=$?
    (( $STATUS == 0 )) && break
    [[ $OUT == *InvalidClientTokenId* ]] || _die $OUT
  done
  _log ">> Deactivated previous key: $ACCESS_KEY"

  ROTATED=$((ROTATED + 1))
  _log ">> Rotated $profile."
done

_log "Done. Rotated $ROTATED key(s)."