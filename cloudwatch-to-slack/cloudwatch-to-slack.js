'use strict';
/*
    CloudWatch to Slack lambda function
    Copyright Ai-SOFT Inc.
*/
const AWS = require('aws-sdk');
const url = require('url');
const https = require('https');

const iconBase = 'https://aispub.s3.amazonaws.com/awsicons';
const kmsEncryptedHookUrl = process.env.kmsEncryptedHookUrl;
const slackChannelDefault = process.env.slackChannel;
const DEBUG = process.env.DEBUG;
let hookUrl;

const alermColor = {
    OK: 'good',
    ALARM: 'danger',
    INSUFFICIENT_DATA: 'warning',
};
const rdsEventColor = {
    'RDS-EVENT-0006': 'good',       // restarted
    'RDS-EVENT-0004': 'warning',    // shutting down
    'RDS-EVENT-0022': 'danger',     // reboot failure
    'RDS-EVENT-0005': 'good',       // creating
    'RDS-EVENT-0003': 'danger',     // deleting
    'RDS-EVENT-0034': 'danger',     // failover skipped
    'RDS-EVENT-0013': 'warning',    // failover started
    'RDS-EVENT-0015': 'good',       // failover completed
    'RDS-EVENT-0065': 'good',       // recovered from partial failover
    'RDS-EVENT-0049': 'good',       // Multi-AZ failover completed
    'RDS-EVENT-0050': 'warning',    // Multi-AZ activation started
    'RDS-EVENT-0051': 'good',       // Multi-AZ activation completed
    'RDS-EVENT-0031': 'danger',     // instance failure
    'RDS-EVENT-0036': 'danger',     // incompatible network
    'RDS-EVENT-0035': 'danger',     // incompatible parameter
    'RDS-EVENT-0058': 'danger',     // statspack failure
    'RDS-EVENT-0079': 'danger',     // extended monitoring failure
    'RDS-EVENT-0080': 'danger',     // extended monitoring failure
    'RDS-EVENT-0081': 'danger',     // SQL Server backup failure
    'RDS-EVENT-0082': 'danger',     // S3 failure
    'RDS-EVENT-0089': 'warning',    // low storage space
    'RDS-EVENT-0007': 'danger',     // no storage space left
    'RDS-EVENT-0026': 'danger',     // offline maintenance running
    'RDS-EVENT-0027': 'good',       // offline maintenance completed
    'RDS-EVENT-0047': 'good',       // instance patched
    'RDS-EVENT-0048': 'warning',    // instance patch delayed
    'RDS-EVENT-0054': 'warning',    // engine is not innodb
    'RDS-EVENT-0055': 'warning',    // too many tables
    'RDS-EVENT-0056': 'warning',    // too many databases
    'RDS-EVENT-0087': 'warning',    // instance stopped
    'RDS-EVENT-0088': 'good',       // instance started
    'RDS-EVENT-0045': 'danger',     // read replica failure
    'RDS-EVENT-0046': 'good',       // read replica started
    'RDS-EVENT-0057': 'warning',    // read replica stopped
    'RDS-EVENT-0062': 'warning',    // read replica stopped manually
    'RDS-EVENT-0063': 'warning',    // read replica reset
    'RDS-EVENT-0020': 'danger',     // instance recovery started
    'RDS-EVENT-0021': 'good',       // instance recovery completed
    'RDS-EVENT-0052': 'danger',     // Multi-AZ recovery started
    'RDS-EVENT-0053': 'good',       // Multi-AZ recovery completed
    'RDS-EVENT-0066': 'warning',    // mirror recovering
    'RDS-EVENT-0008': 'good',       // instance recovered from snapshot
    'RDS-EVENT-0019': 'good',       // instance recovered from point
};
const elasticacheColor = {
    Complete: 'good',
    Failed: 'danger',
    Rebooted: 'warning',
};
const codeDeployColor = {
    CREATED: '#439FE0',
    SUCCEEDED: 'good',
    FAILED: 'danger',
    ROLLEDBACK: 'warning',
};
const runCommandColor = {
    Pending: '#aaaaaa',
    InProgress: '#439FE0',
    Delayed: 'warning',
    Success: 'good',
    Cancelled: 'warning',
    TimedOut: 'danger',
    Failed: 'danger',
    Cancelling: '#888888',
};
const healthTypeColor = {
    issue: 'warning',
    scheduledChange: '#888888',
    accountNotification: '#439FE0',
};
const propMap = {
    'AlarmName': CloudWatchMessage,
    'Source ID': RDSMessage,
    'configurationItem': ConfigChangeMessage,
    's3Bucket': ConfigHistoryMessage,
    'deploymentId': CodeDeployMessage,
    'commandId': RunCommandMessage,
    'hostname': EC2Message,
};

function epoch(date) {
    if (!(date instanceof Date)) date = new Date(date);
    return Math.floor(date.getTime() / 1000);
}

function postMessage(message) {
    return new Promise((resolve, reject) => {
        if (DEBUG) console.log(message);
        const body = JSON.stringify(message);
        const options = url.parse(hookUrl);
        options.method = 'POST';
        options.headers = {
            'Content-Type': 'application/json',
            'Content-Length': Buffer.byteLength(body),
        };
        const req = https.request(options, (res) => {
            const chunks = [];
            res.setEncoding('utf8');
            res.on('data', chunk => chunks.push(chunk));
            res.on('end', () => {
                resolve({
                    body: chunks.join(''),
                    statusCode: res.statusCode,
                    statusMessage: res.statusMessage,
                });
            });
            return res;
        });
        req.on('error', reject);
        req.write(body);
        req.end();
    });
}

function SimpleMessage(subject, message) {
    return {
        username: 'Event Notification',
        icon_url: `${iconBase}/SNS.png`,
        attachments: [{
            title: subject,
            fallback: 'Unknown Event Notification',
            fields: Object.entries(message).map(([key, value]) => (
                {title: key, value: JSON.stringify(value), short: false}
            )),
        }],
    };
}

function RawMessage(snsMessage) {
    let message = snsMessage.Message;
    if (snsMessage.Subject) message = `*${snsMessage.Subject}*\n${message}`;
    return {
        username: snsMessage.Type,
        icon_url: `${iconBase}/SNS.png`,
        text: message,
    };
}

function CloudWatchMessage(subject, message) {
    const alarmName = message.AlarmName;
    const alarmDesc = message.AlarmDescription || message.AlarmName;
//    const oldState = message.OldStateValue;
    const newState = message.NewStateValue;
    const reason = message.NewStateReason;
    const accountId = message.AWSAccountId;
    const region = message.Region;
    const stateChangeTime = message.StateChangeTime;

    let messageText = `*${newState}*: ${alarmDesc}`;
    if (newState != 'OK') messageText += `\n${reason}`;

    return {
        username: 'CloudWatch',
        icon_url: `${iconBase}/CloudWatch.png`,
        attachments: [{
            fallback: `${newState}: ${alarmDesc}`,
            text: messageText,
            color: alermColor[newState] || '#000000',
            footer: `${alarmName} - ${region} - ${accountId}`,
            ts: epoch(stateChangeTime),
        }],
    };
}

function RDSMessage(subject, message) {
    const sourceId = message['Source ID'];
    const eventId = message['Event ID'];
    const eventMessage = message['Event Message'];
    const eventTime = message['Event Time'].substr(0, 19);
    const identifierLink = message['Identifier Link'];

    const slackMessage = {
        username: 'Amazon RDS',
        icon_url: `${iconBase}/RDS.png`,
        attachments: [{
            fallback: `${sourceId} - ${eventMessage}`,
            text: `*<${identifierLink}|${sourceId}>*\n${eventMessage}`,
            ts: epoch(eventTime),
        }],
    };

    const match = /#(RDS-EVENT-\d+)$/.exec(eventId);
    if (match) {
        slackMessage.attachments[0].color = rdsEventColor[match[1]];
        slackMessage.attachments[0].footer = match[1];
    }

    return slackMessage;
}

function ElastiCacheMessage(subject, message) {
    const textMessage = [];
    let color = null;
    for (const [key, value] of Object.entries(message)) {
        const filteredKey = key.replace(/^ElastiCache:/, '');
        textMessage.push(`${filteredKey} : ${value}`);
        if (!color) {
            const found = Object.entries(elasticacheColor).
                find(e => filteredKey.endsWith(e[0]));
            if (found) color = found[1];
        }
    }
    return {
        username: 'ElastiCache',
        icon_url: `${iconBase}/ElastiCache.png`,
        attachments: [{
            text: textMessage.join("\n"),
            color: color,
        }],
    };
}

function CodeDeployMessage(subject, message) {
    return {
        username: 'CodeDeploy',
        icon_url: `${iconBase}/CodeDeploy.png`,
        attachments: [{
            title: subject,
            color: codeDeployColor[message.status],
            fields: ['createTime', 'completeTime'].map(k => (
                {title: k, value: message[k], short: true}
            )),
            footer: `${message.eventTriggerName} - ${message.applicationName} - ${message.deploymentGroupName}`,
            ts: epoch(message.completeTime || message.createTime),
        }],
    };
}

async function RunCommandMessage(subject, message) {
    const SSM = new AWS.SSM();
    const invokation = await SSM.getCommandInvocation({
        CommandId: message.commandId,
        InstanceId: message.instanceId
    }).promise();

    const slackMessage = {
        username: 'Systems Manager',
        icon_url: `${iconBase}/EC2SystemsManager.png`,
        attachments: [{
            title: `${message.status}: ${message.documentName} at ${message.instanceId} (code: ${invokation.ResponseCode})`,
            color: runCommandColor[message.status],
            fields: [],
            footer: message.commandId,
            ts: epoch(message.requestedDateTime),
        }],
    };
    for (const [field, label] of [['StandardOutputContent', 'stdout'], ['StandardErrorContent', 'stderr']]) {
        if (invokation[field]) {
            slackMessage.attachments[0].fields.push({title: label, value: invokation[field], short: false});
        }
    }
    return slackMessage;
}

function EC2Message(subject, message) {
    return {
        username: `EC2 - ${message.hostname}`,
        icon_url: `${iconBase}/EC2.png`,
        attachments: [{
            title: subject,
            text: message.message,
            footer: `${message.instanceId} @ ${message.availabilityZone}`,
        }],
    };
}

function ConfigChangeMessage(subject, message) {
    const item = message.configurationItem;
    const itemDiff = message.configurationItemDiff;
    const creationTime = message.notificationCreationTime;
    const changedProps = Object.keys(itemDiff.changedProperties);
    const slackMessage = {
        username: 'AWS Config',
        icon_url: `${iconBase}/Config.png`,
        text: `${itemDiff.changeType} - ${item.resourceType} ${item.resourceName}`,
        attachments: [{
            fallback: message.messageType,
            footer: `${item.awsRegion} - ${item.awsAccountId}`,
            ts: epoch(creationTime),
        }],
    };
    if (changedProps.length) {
        slackMessage.attachments[0].fields = [{
            title: 'Properties',
            value: changedProps.join("\n"),
            short: false,
        }];
    }
    return slackMessage;
}

function ConfigHistoryMessage(subject, message) {
    const match = /AWSLogs\/(\d+)\/(CloudTrail|Config)\/([\w\-]+)/.exec(message.s3ObjectKey);
    const isConfig = match[2] === 'Config';
    return {
        username: isConfig ? 'AWS Config' : 'CloudTrail',
        icon_url: `${iconBase}/${match[2]}.png`,
        text: `Configuration History Delivery Completed: ${match[3]} - ${match[1]}`,
    };
}

function CloudFormationMessage(message) {
    const stackName = /StackName='(.*?)'/.exec(message);
    const resourceType = /ResourceType='(.*?)'/.exec(message);
    const resourceStatus = /ResourceStatus='(.*?)'/.exec(message);
    return {
        username: 'CloudFormation',
        icon_url: `${iconBase}/CloudFormation.png`,
        text: `${stackName[1]}: ${resourceStatus[1]} - ${resourceType[1]}`,
    };
}

function HealthMessage(subject, message) {
    const detail = message.detail;
    const url = `https://phd.aws.amazon.com/phd/home?region=${message.region}#/event-log?eventID=${detail.eventArn}`;
    return {
        username: 'AWS Health',
        icon_url: `${iconBase}/AWS.png`,
        attachments: [{
            color: healthTypeColor[detail.eventTypeCategory],
            text: `${detail.eventTypeCategory} - ${detail.eventTypeCode}\n` +
                  `${detail.eventDesceription[0].latestDescription}\n` +
                  `<${url}|Click here for details>`,
            fallback: detail.eventDesceription[0].latestDescription,
            footer: message.region,
            ts: epoch(message.time),
        }],
    };
}

function AmazonIpSpaceChangedMessage(subject, message) {
    return {
        username: 'AWS',
        icon_url: `${iconBase}/AWS.png`,
        attachments: [{
            title: subject,
            text: message.url,
            ts: epoch(message['create-time'].replace(/^(\d+-\d+-\d+)-(\d+)-(\d+)-(\d+)$/, "$1 $2:$3:$4 UTC")),
        }],
    };
}

function SnsMessage(snsMessage) {
    if (snsMessage.Subject === 'AWS CloudFormation Notification') {
        return CloudFormationMessage(snsMessage.Message);
    }
    try {
        const subject = snsMessage.Subject;
        const message = JSON.parse(snsMessage.Message);
        if (snsMessage.TopicArn === 'arn:aws:sns:us-east-1:806199016981:AmazonIpSpaceChanged') {
            return AmazonIpSpaceChangedMessage(subject, message);
        }
        if (message.source === 'aws.health') {
            return HealthMessage(subject, message);
        }
        for (const [prop, func] of Object.entries(propMap)) {
            if (message[prop]) return func(subject, message);
        }
        if (Object.keys(message).some(key => /^ElastiCache:/.test(key))) {
            return ElastiCacheMessage(subject, message);
        }
        return SimpleMessage(subject, message);
    } catch (e) {
        console.error(`Error while building message: ${e.type}: ${e.message}`);
        return RawMessage(snsMessage);
    }
}

function buildMessage(event) {
    if (DEBUG) console.log(`incoming event: ${JSON.stringify(event, null, '  ')}`);
    if (event.Records && event.Records[0].EventSource === 'aws:sns') {
        return SnsMessage(event.Records[0].Sns);
    }
}

function getSlackChannel(event) {
    const topic = event.Records[0].Sns.TopicArn;
    const match = topic && /^arn:aws:sns:[^:]+:[^:]+:(.*)/.exec(topic);
    if (match) {
        return process.env[`slackChannel_${match[1]}`] || slackChannelDefault;
    } else {
        return slackChannelDefault;
    }
}

async function processEvent(event) {
    const slackMessage = await buildMessage(event);
    if (!slackMessage) {
        console.error('Failed to parse message');
        return;
    }
    slackMessage.channel = getSlackChannel(event);
    const response = await postMessage(slackMessage);
    if (response.statusCode < 400) {
        console.info('Message posted successfully');
        return;
    }
    if (response.statusCode < 500) {
        console.error(`Error posting message to Slack API: ${response.statusCode} - ${response.statusMessage}`);
        return;  // Don't retry because the error is due to a problem with the request
    }
    // Let Lambda retry
    console.log(response.body);
    throw new Error(`Server error when processing message: ${response.statusCode} - ${response.statusMessage}`);
}

exports.handler = async (event) => {
    if (!hookUrl && kmsEncryptedHookUrl && kmsEncryptedHookUrl !== '<kmsEncryptedHookUrl>') {
        const kms = new AWS.KMS();
        const cipherText = {CiphertextBlob: new Buffer(kmsEncryptedHookUrl, 'base64')};
        const data = await kms.decrypt(cipherText).promise();
        hookUrl = `https://${data.Plaintext.toString('ascii')}`;
    }
    if (!hookUrl) {
        throw new Error('Hook URL has not been set.');
    }
    return processEvent(event);
};
