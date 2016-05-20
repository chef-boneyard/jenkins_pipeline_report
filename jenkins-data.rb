require "optparse"
require_relative "jenkins_data"
require "pp"

refresh_options = {}
OptionParser.new do |opts|
  opts.banner = <<-EOM
    USAGE: ruby jenkins-data.rb JOB_URL ...

    Download and cache Jenkins data.

    ruby jenkins-data.rb https://manhattan.ci.chef.co/job/chef-trigger-release https://wilson.ci.chef.co/job/chef-server-12-trigger-release

    You must upload your public SSH key to your Jenkins server from ~/.ssh/id_rsa.
  EOM

  opts.on("--[no-]force-refresh-runs", "Whether to refresh run data for all runs regardless of whether they've been fetched before (default: false)") do |v|
    refresh_options[:force_refresh_runs] = v
  end
  opts.on("--[no-]force-refresh-omnibus-timing", "Whether to refresh omnibus timing for all runs regardless of whether they've been fetched before (default: false)") do |v|
    refresh_options[:force_refresh_omnibus_timing] = v
  end
  opts.on("--[no-]force", "Whether to refresh all data regardless of whether they've been fetched before (default: false)") do |v|
    refresh_options[:force_refresh_all] = v
  end
end.parse!

ARGV.each do |job_url|
  JenkinsData.new(job_url: job_url).refresh(refresh_options)
end
