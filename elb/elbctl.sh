#!/bin/bash
set -euo pipefail

_die() { echo >&2 "$@"; exit 1; }
_usage() { _die "usage: $0 {start|stop} <TargetGroupName>"; }

if which ec2metadata 2>/dev/null; then
  _meta() { ec2metadata "$@"; }
elif which ec2-metadata 2>/dev/null; then
  _meta() { ec2-metadata "$@" | awk '{print $2}'; }
else
  _die "Neither ec2metadata nor ec2-metadata found."
fi

AZ=$(_meta --availability-zone)
export AWS_DEFAULT_REGION="${AZ%[a-z]}"
echo "Region=$AWS_DEFAULT_REGION"

INSTANCE_ID=$(_meta --instance-id)
echo "InstanceId=$INSTANCE_ID"

set +eu
ACTION="$1"
TARGET_GROUP_NAME="$2"
set -eu
[ -z "$TARGET_GROUP_NAME" ] && _usage
TARGET_GROUP_ARN=$(aws elbv2 describe-target-groups \
  --names "$TARGET_GROUP_NAME" \
  --query 'TargetGroups[0].TargetGroupArn' --output text)
[ -z "$TARGET_GROUP_ARN" ] && _die "TargetGroup $TARGET_GROUP_NAME not found."
echo "TargetGroupArn=$TARGET_GROUP_ARN"

case $ACTION in
  start )
    echo "Registering..."
    aws elbv2 register-targets \
      --target-group-arn "$TARGET_GROUP_ARN" \
      --targets "Id=$INSTANCE_ID" --output text
    aws elbv2 wait target-in-service \
      --target-group-arn "$TARGET_GROUP_ARN" \
      --targets "Id=$INSTANCE_ID" --output text
    ;;
  stop )
    echo "Deregistering..."
    aws elbv2 deregister-targets \
      --target-group-arn "$TARGET_GROUP_ARN" \
      --targets "Id=$INSTANCE_ID" --output text
    aws elbv2 wait target-deregistered \
      --target-group-arn "$TARGET_GROUP_ARN" \
      --targets "Id=$INSTANCE_ID" --output text
    ;;
  * )
    _usage
esac
echo "Done."
