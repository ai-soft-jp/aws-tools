#!/usr/bin/env ruby
#
require 'bundler/setup'
require 'aws-sdk-guardduty'
require 'optparse'
require 'shellwords'

def die(*mesg, exitstatus: 1)
  $stderr.puts *mesg
  exit exitstatus
end
def log(mesg)
  # No action
end

config = {
  postmap: 'postmap',
}

o = OptionParser.new
o.on('-d PATH', '--domain-map', String, 'Path to domain map file') { |v| config[:domainmap] = v }
o.on('-m PATH', '--postmap', String, 'Path to postmap program (default: search in $PATH)') { config[:postmap] = v }
o.on('-a', '--archive', 'Archive finding automatically') { config[:archive] = true }
o.on('-e DAYS', '--expires', Integer, 'Remove from list after specified DAYS') { |v| config[:expires] = v }
o.on('-v', '--verbose', 'Be verbose') { config[:verbose] = true }
o.on('-h', '--help', 'Show this help') { puts o; exit }
begin
  o.parse!(ARGV)
rescue => e
  die e.message
end

unless config[:domainmap]
  die "Specify path to domain map file."
end
if config[:verbose]
  def log(mesg)
    $stderr.puts mesg
  end
end

dmapf = open(config[:domainmap], File::RDWR | File::CREAT)
dmap = {}
while line = dmapf.gets
  if /\A\s*#/ =~ line
    comment = line.strip
  elsif /\A\s*\z/ =~ line
    # Skip
  else
    domain, action = line.chomp.split(/\t+/)
    dmap[domain] = [action, comment]
    comment = nil
  end
end
log "#{config[:domainmap]}: Fetched #{dmap.size} domains."

gd = Aws::GuardDuty::Client.new
detector_id = gd.list_detectors.detector_ids.first
log "GuardDuty: detectorId is #{detector_id}."
token = ''
archives = []
begin
  finding_ids = gd.list_findings(
    detector_id: detector_id,
    finding_criteria: {
      criterion: {
        'service.archived': {eq: ['false']},
        'service.action.actionType': {eq: ['DNS_REQUEST']},
      }
    },
    max_results: 50,
    next_token: token
  )
  token = finding_ids.next_token

  findings = gd.get_findings(
    detector_id: detector_id,
    finding_ids: finding_ids.finding_ids,
  )
  findings.findings.each do |finding|
    domain = finding.service.action.dns_request_action.domain
    log "Finding: #{finding.type} #{domain}"
    archives << finding.id if dmap[domain]
    dmap[domain] = [
      "REJECT Access denied by GuardDuty",
      "# #{finding.type} @ #{finding.service.event_last_seen}",
    ]
  end
end while token != ''

if config[:archive] && !archives.empty?
  archives.each_slice(50) do |finding_ids|
    gd.archive_findings(
      detector_id: detector_id,
      finding_ids: finding_ids
    )
  end
  log "GuardDuty: Archived #{archives.size} findings."
end

if config[:expires]
  require 'time'
  threshold = Time.now.to_i
  threshold -= threshold % 86400
  threshold -= config[:expires] * 86400
  log "Threashold is #{Time.at(threshold)}"
  dmap.reject! do |domain, (action, comment)|
    if /@ (\S+)/ =~ comment
      last_seen = $1
      begin
        if Time.parse(last_seen).to_i < threshold
          log "#{domain}: Expired. Last seen at #{last_seen}."
          true
        end
      rescue
        false
      end
    end
  end
end

dmapf.rewind
dmapf.puts "# auto-generated by #{File.basename($0)} @ #{Time.now}"
dmapf.puts
dmap.each do |domain, (action, comment)|
  dmapf.puts comment
  dmapf.puts "#{domain}\t#{action}"
end
dmapf.truncate(dmapf.pos)
dmapf.fdatasync
dmapf.close
log "#{config[:domainmap]}: Written #{dmap.size} domains."
system "#{Shellwords.escape(config[:postmap])} #{Shellwords.escape(config[:domainmap])}"
