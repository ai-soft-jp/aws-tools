/*
	ec2-auto-backup lambda function for Node 8.x
*/
const AWS = require('aws-sdk');
const ec2 = new AWS.EC2();

const DEFAULT_KEEP = parseInt(process.env.DEFAULT_KEEP, 10) || 28;

function datestr(date) {
	date = date || new Date();
	return date.toISOString().substr(0, 10).replace(/-/g, '/');
}
function findTag(resource, name) {
	const tag = resource.Tags.find(t => t.Key === name);
	return tag && tag.Value;
}

const _eachPage = AWS.Request.prototype.eachPage;
AWS.Request.prototype.eachPage = function eachPage(callback) {
	return new Promise((resolve, reject) => {
		_eachPage.call(this, (err, data, done) => {
			if (err) reject(err);
			else if (!data) resolve();
			else callback(data).then(done, reject);
		});
	});
};

async function processInstance(instance) {
	if(findTag(instance, 'NoBackup')) return;

	instance.instanceName = findTag(instance, 'Name');
	if(!instance.instanceName) throw new Error(`${instance.InstanceId}: no Name tag`);

	instance.prefix = `${instance.InstanceId}(${instance.instanceName})`;
	console.log(`${instance.prefix}: processInstance`);

	await ec2.describeVolumes({
		Filters: [
			{Name: 'attachment.instance-id', Values: [instance.InstanceId]},
			{Name: 'status', Values: ['in-use']}
		]
	}).eachPage(async (data) => {
		for (const volume of data.Volumes) {
			await processVolume(instance, volume);
		}
	});
}

async function processVolume(instance, volume) {
	if(findTag(volume, 'NoBackup')) return;

	const device = volume.Attachments[0].Device;
	const description = `${instance.instanceName} backup ${datestr()} from ${device}`;

	const snapshot = await ec2.createSnapshot({
		VolumeId: volume.VolumeId,
		Description: description
	}).promise();
	console.log(`${instance.prefix}: created snapshot ${snapshot.SnapshotId} from ${device}`);

	await ec2.createTags({
		Resources: [snapshot.SnapshotId],
		Tags: [
			{Key: 'Name', Value: instance.instanceName},
			{Key: 'Backup', Value: instance.instanceName},
			{Key: 'Device', Value: device}
		]
	}).promise();
	console.log(`${instance.prefix}: tagged ${snapshot.SnapshotId} Name=${instance.instanceName} Backup=${instance.instanceName} Decice=${device}`);

	await cleanupSnapshots(instance, volume);
}

async function cleanupSnapshots(instance, volume) {
	const device = volume.Attachments[0].Device;
	const keep = parseInt(findTag(volume, 'Backup'), 10) || DEFAULT_KEEP;

	const snapshots = [];
	await ec2.describeSnapshots({
		OwnerIds: ['self'],
		Filters: [
			{Name: 'tag:Backup', Values: [instance.instanceName]},
			{Name: 'tag:Device', Values: [device]}
		]
	}).eachPage(async (data) => {
		for (const snapshot of data.Snapshots) {
			snapshots.push(snapshot);
		}
	});
	snapshots.sort((a, b) => b.StartTime.getTime() - a.StartTime.getTime());

	for (const snapshot of snapshots.slice(keep)) {
		await ec2.deleteSnapshot({SnapshotId: snapshot.SnapshotId}).promise();
		console.log(`${instance.prefix}: deleted snapshot ${snapshot.SnapshotId} (${snapshot.Description})`);
	}
}

exports.handler = async (event) => {
	await ec2.describeInstances({
		Filters: [{Name: 'instance-state-name', Values: ['running']}]
	}).eachPage(async (data) => {
		for (const r of data.Reservations) {
			for (const instance of r.Instances) {
				await processInstance(instance);
			}
		}
	});
};
