import * as https from 'node:https';
import * as calc from 'cidr-calc';
import * as ipaddr from 'ip-address';

const URLS = {
  AFRINIC: 'https://ftp.afrinic.net/pub/stats/afrinic/delegated-afrinic-extended-latest',
  APNIC: 'https://ftp.apnic.net/stats/apnic/delegated-apnic-extended-latest',
  ARIN: 'https://ftp.arin.net/pub/stats/arin/delegated-arin-extended-latest',
  LACNIC: 'https://ftp.lacnic.net/pub/stats/lacnic/delegated-lacnic-extended-latest',
  RIPE: 'https://ftp.ripe.net/ripe/stats/delegated-ripencc-extended-latest',
};

const countries = process.argv
  .slice(2)
  .flatMap((s) => s.toUpperCase().split(','))
  .filter((s) => s);
if (!countries.length) {
  console.error(`usage: ${process.argv[1]} <country codes...>`);
  process.exit(1);
}

await Promise.all(
  Object.values(URLS).map(async (url) => {
    try {
      await processList(url);
    } catch (err) {
      console.error(`ERROR while processing ${url}`);
      console.error(err);
      process.exit(1);
    }
  }),
);

async function processList(url) {
  let data = '';
  await new Promise((resolve, reject) => {
    const req = https.get(url, { family: 4 }, (res) => {
      if (res.statusCode !== 200) return reject(new Error(`${url}: ${res.statusCode}`));
      res.setEncoding('utf8');
      res.on('data', (chunk) => (data = data.concat(chunk)));
      res.on('end', () => resolve());
    });
    req.on('error', reject);
  });
  for (const line of data.split('\n')) {
    if (line.startsWith('#') || line.trim() === '') continue;
    const row = line.split('|');
    if (!(['ipv4', 'ipv6'].includes(row[2]) && countries.includes(row[1]))) continue;
    if (row[2] === 'ipv4') {
      const startip = new ipaddr.Address4(row[3]);
      const endip = ipaddr.Address4.fromBigInt(startip.bigInt() + BigInt(parseInt(row[4], 10) - 1));
      const range = new calc.IpRange(calc.IpAddress.of(startip.address), calc.IpAddress.of(endip.address));
      for (const cidr of range.toCidrs()) {
        console.log(cidr.toString());
      }
    } else {
      console.log(`${row[3].toLowerCase()}/${row[4]}`);
    }
  }
}
