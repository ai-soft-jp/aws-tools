#!/bin/bash
#
_die() { echo >&2 "$@"; exit 1; }

export AWS_PROFILE=aisoft
SNS_ARN=$1
ALIAS=$2

[[ -z "$SNS_ARN" || -z "$ALIAS" ]] && _die "usage: $0 <sns-arn> <alias>"
ACCOUNT=$(expr "$SNS_ARN" : 'arn:aws:sns:[^:]*:\([0-9]*\):.*')
[[ -z "$ACCOUNT" ]] && _die "Malformed arn"

aws lambda add-permission \
      --function-name cloudwatch-to-slack \
      --statement-id allow-${ACCOUNT}-${ALIAS} \
      --action lambda:InvokeFunction \
      --principal sns.amazonaws.com \
      --source-arn ${SNS_ARN}
aws sns subscribe \
      --topic-arn ${SNS_ARN} \
      --protocol lambda \
      --notification-endpoint arn:aws:lambda:ap-northeast-1:837492605293:function:cloudwatch-to-slack
