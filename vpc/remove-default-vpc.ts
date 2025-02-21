import {
  EC2,
  NetworkInterface,
  paginateDescribeEgressOnlyInternetGateways,
  paginateDescribeInternetGateways,
  paginateDescribeNetworkAcls,
  paginateDescribeNetworkInterfaces,
  paginateDescribeRouteTables,
  paginateDescribeSecurityGroupRules,
  paginateDescribeSecurityGroups,
  paginateDescribeSubnets,
  paginateDescribeVpcEndpoints,
  paginateDescribeVpcs,
  RouteTable,
  SecurityGroup,
  Tag,
  Vpc,
} from '@aws-sdk/client-ec2';
import * as readline from 'readline/promises';
import yargs from 'yargs';
import { hideBin } from 'yargs/helpers';

const rl = readline.createInterface({ input: process.stdin, output: process.stdout });
const args = await yargs(hideBin(process.argv))
  .option('region', {
    type: 'string',
    array: true,
    description: 'AWS Region to scan',
    defaultDescription: 'All regions',
  })
  .option('profile', {
    type: 'string',
    description: 'AWS CLI Profile',
    defaultDescription: 'AWS_PROFILE',
  })
  .option('debug', {
    type: 'boolean',
    description: 'Turn on debug output',
  })
  .strict()
  .parse();
const logger = args.debug ? console : undefined;

async function main() {
  const regions = args.region?.length ? args.region : await getRegions();

  const regionsBlank: string[] = [];
  const regionsUsing: Record<string, NetworkInterface[]> = {};
  const regionsDeletable: Record<string, ProcessRegion> = {};

  console.log(`*** Scanning regions...`);
  await Promise.all(
    regions.map(async (region) => {
      const processor = new ProcessRegion(region);

      const defaultVpc = await processor.getDefaultVpc();
      if (!defaultVpc) {
        regionsBlank.push(region);
        return;
      }
      const enis = await processor.getENIs();
      if (enis.length) {
        regionsUsing[region] = enis;
        return;
      }
      regionsDeletable[region] = processor;
    }),
  );

  if (regionsBlank.length) {
    console.log(`No default VPC: ${regionsBlank.join(', ')}`);
  }
  if (Object.keys(regionsUsing).length) {
    console.log(`Using default VPC: ${Object.keys(regionsUsing).join(', ')}`);
  }
  if (Object.keys(regionsDeletable).length) {
    console.log(`Deletable default VPC: ${Object.keys(regionsDeletable).join(', ')}`);
  } else {
    return;
  }

  console.log('');
  for (;;) {
    const cont = await rl.question('Type [yes] to delete default VPCs: ');
    if (['n', 'no'].includes(cont.toLowerCase())) return;
    if (['yes'].includes(cont.toLowerCase())) break;
  }

  for (const [region, processor] of Object.entries(regionsDeletable)) {
    console.log('');
    await processor.deleteDefaultVpc();
  }
}

async function getRegions() {
  const ec2 = new EC2({ region: 'us-east-1', logger });
  const res = await ec2.describeRegions();
  return res.Regions!.map((region) => region.RegionName!);
}

function getName(tags?: Tag[]) {
  const name = tags?.find(({ Key }) => Key === 'Name')?.Value;
  return name ? ` (${name})` : '';
}

class ProcessRegion {
  readonly ec2: EC2;
  private _defaultVpc?: Vpc;

  get vpcId() {
    return this._defaultVpc!.VpcId!;
  }

  constructor(readonly region: string) {
    this.ec2 = new EC2({ region, logger });
  }

  async getDefaultVpc() {
    const req = paginateDescribeVpcs({ client: this.ec2 }, {});
    for await (const res of req) {
      const defaultVpc = res.Vpcs?.find((vpc) => vpc.IsDefault);
      if (defaultVpc) return (this._defaultVpc = defaultVpc);
    }
  }

  async getENIs() {
    const req = paginateDescribeNetworkInterfaces(
      { client: this.ec2 },
      { Filters: [{ Name: 'vpc-id', Values: [this.vpcId] }] },
    );
    const enis: NetworkInterface[] = [];
    for await (const res of req) {
      enis.push(...(res.NetworkInterfaces ?? []));
    }
    return enis;
  }

  async deleteDefaultVpc() {
    console.log(`*** Deleting Default VPC [${this.vpcId}] in ${this.region}...`);
    await this.deleteSecurityGroups();
    await this.deleteNetworkAcls();
    await this.deleteVpcEndpoints();
    const routeTables = await this.lookupRouteTables();
    await this.purgeRouteTables(routeTables);
    await this.deleteSubnets();
    await this.deleteRouteTables(routeTables);
    await this.deleteInternetGateways();
    await this.deleteEgressOnlyInternetGateways();
    console.log(`>>> Deleting VPC: ${this.vpcId}`);
    await this.ec2.deleteVpc({ VpcId: this.vpcId });
    console.log(`<<< DONE!`);
  }

  async deleteSecurityGroups() {
    const req = paginateDescribeSecurityGroups(
      { client: this.ec2 },
      { Filters: [{ Name: 'vpc-id', Values: [this.vpcId] }] },
    );
    const securityGroups: SecurityGroup[] = [];
    for await (const res of req) {
      securityGroups.push(...(res.SecurityGroups ?? []));
    }
    for (const sg of securityGroups) {
      await this.purgeSecurityGroupRules(sg);
    }
    for (const sg of securityGroups) {
      if (sg.GroupName !== 'default') {
        console.log(`>>> Deleting securigy group: ${sg.GroupId} (${sg.GroupName})`);
        await this.ec2.deleteSecurityGroup({ GroupId: sg.GroupId });
      }
    }
  }

  async purgeSecurityGroupRules(sg: SecurityGroup) {
    const req = paginateDescribeSecurityGroupRules(
      { client: this.ec2 },
      { Filters: [{ Name: 'group-id', Values: [sg.GroupId!] }] },
    );
    for await (const res of req) {
      if (res.SecurityGroupRules?.length) {
        console.log(`>>> Purging securigy group rules: ${sg.GroupId} (${sg.GroupName})`);
      }
      const ingressRules = res.SecurityGroupRules?.filter((r) => !r.IsEgress).map((r) => r.SecurityGroupRuleId!);
      const egressRules = res.SecurityGroupRules?.filter((r) => r.IsEgress).map((r) => r.SecurityGroupRuleId!);
      if (ingressRules?.length) {
        await this.ec2.revokeSecurityGroupIngress({ GroupId: sg.GroupId, SecurityGroupRuleIds: ingressRules });
      }
      if (egressRules?.length) {
        await this.ec2.revokeSecurityGroupEgress({ GroupId: sg.GroupId, SecurityGroupRuleIds: egressRules });
      }
    }
  }

  async deleteVpcEndpoints() {
    const req = paginateDescribeVpcEndpoints(
      { client: this.ec2 },
      { Filters: [{ Name: 'vpc-id', Values: [this.vpcId] }] },
    );
    for await (const res of req) {
      for (const vpce of res.VpcEndpoints ?? []) {
        console.log(`>>> Deleting VPC endpoint: ${vpce.VpcEndpointType} / ${vpce.VpcEndpointId}${getName(vpce.Tags)}`);
        await this.ec2.deleteVpcEndpoints({ VpcEndpointIds: [vpce.VpcEndpointId!] });
      }
    }
  }

  async lookupRouteTables() {
    const req = paginateDescribeRouteTables(
      { client: this.ec2 },
      { Filters: [{ Name: 'vpc-id', Values: [this.vpcId] }] },
    );
    const routeTables: RouteTable[] = [];
    for await (const res of req) {
      routeTables.push(...(res.RouteTables ?? []));
    }
    return routeTables;
  }

  async purgeRouteTables(routeTables: RouteTable[]) {
    for (const rt of routeTables) {
      if (!rt.Routes?.length) return;
      console.log(`>>> Purging route table ${rt.RouteTableId}${getName(rt.Tags)}`);
      for (const route of rt.Routes) {
        if (route.GatewayId === 'local') continue;
        await this.ec2.deleteRoute({
          RouteTableId: rt.RouteTableId,
          DestinationCidrBlock: route.DestinationCidrBlock,
          DestinationIpv6CidrBlock: route.DestinationIpv6CidrBlock,
          DestinationPrefixListId: route.DestinationPrefixListId,
        });
      }
      for (const assoc of rt.Associations ?? []) {
        if (assoc.Main) continue;
        await this.ec2.disassociateRouteTable({ AssociationId: assoc.RouteTableAssociationId });
      }
    }
  }

  async deleteRouteTables(routeTables: RouteTable[]) {
    for (const rt of routeTables) {
      if (rt.Associations?.some((assoc) => assoc?.Main)) continue;
      console.log(`>>> Deleting route table: ${rt.RouteTableId}${getName(rt.Tags)}`);
      await this.ec2.deleteRouteTable({ RouteTableId: rt.RouteTableId });
    }
  }

  async deleteSubnets() {
    const req = paginateDescribeSubnets({ client: this.ec2 }, { Filters: [{ Name: 'vpc-id', Values: [this.vpcId] }] });
    for await (const res of req) {
      for (const subnet of res.Subnets ?? []) {
        console.log(
          `>>> Deleting subnet: ${subnet.SubnetId} in ${subnet.AvailabilityZone} / ${subnet.AvailabilityZoneId}${getName(subnet.Tags)}`,
        );
        await this.ec2.deleteSubnet({ SubnetId: subnet.SubnetId });
      }
    }
  }

  async deleteNetworkAcls() {
    const req = paginateDescribeNetworkAcls(
      { client: this.ec2 },
      { Filters: [{ Name: 'vpc-id', Values: [this.vpcId] }] },
    );
    for await (const res of req) {
      for (const acl of res.NetworkAcls ?? []) {
        if (acl.IsDefault) continue;
        console.log(`>>> Deleting network ACL: ${acl.NetworkAclId}`);
        await this.ec2.deleteNetworkAcl({ NetworkAclId: acl.NetworkAclId });
      }
    }
  }

  async deleteInternetGateways() {
    const req = paginateDescribeInternetGateways(
      { client: this.ec2 },
      { Filters: [{ Name: 'attachment.vpc-id', Values: [this.vpcId] }] },
    );
    for await (const res of req) {
      for (const igw of res.InternetGateways ?? []) {
        console.log(`>>> Deleting internet gateway: ${igw.InternetGatewayId}${getName(igw.Tags)}`);
        await this.ec2.detachInternetGateway({ VpcId: this.vpcId, InternetGatewayId: igw.InternetGatewayId });
        await this.ec2.deleteInternetGateway({ InternetGatewayId: igw.InternetGatewayId });
      }
    }
  }

  async deleteEgressOnlyInternetGateways() {
    const req = paginateDescribeEgressOnlyInternetGateways(
      { client: this.ec2 },
      { Filters: [{ Name: 'attachment.vpc-id', Values: [this.vpcId] }] },
    );
    for await (const res of req) {
      for (const eigw of res.EgressOnlyInternetGateways ?? []) {
        console.log(
          `>>> Deleting Egress-only internet gateway: ${eigw.EgressOnlyInternetGatewayId}${getName(eigw.Tags)}`,
        );
        await this.ec2.deleteEgressOnlyInternetGateway({
          EgressOnlyInternetGatewayId: eigw.EgressOnlyInternetGatewayId,
        });
      }
    }
  }
}

if (args.profile) process.env.AWS_PROFILE = args.profile;
rl.on('SIGINT', () => {
  process.stdout.write('^C\n');
  process.exit(130);
});
main()
  .catch(console.error)
  .finally(() => rl.close());
