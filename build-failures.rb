require "optparse"
require_relative "jenkins_data"
require "pp"

options = { refresh: true }
refresh_options = {}
OptionParser.new do |opts|
  opts.banner = <<-EOM
    USAGE: ruby build-failures.rb JOB_URL ...

    Create a report of build failures.

    ruby build-failures.rb https://manhattan.ci.chef.co/job/chef-trigger-release https://wilson.ci.chef.co/job/chef-server-12-trigger-release

    You must upload your public SSH key to your Jenkins server from ~/.ssh/id_rsa.
  EOM

  opts.on("--[no-]refresh", "Refresh data to latest (default: true)") do |v|
    options[:refresh] = v
  end
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
  jenkins = JenkinsData.new(job_url: job_url)
  if options[:refresh] || refresh_options.any?
    jenkins.refresh(refresh_options)
  end
  jenkins.load.each do |build|
    next if build["result"].nil? || build["result"] == "SUCCESS"
    build_number = File.basename(build["stages"][jenkins.jenkins.job]["url"])
    failure_summary = build["stages"].map do |name,stage|
      unless stage["result"].nil? || stage["result"] == "SUCCESS"
        "#{name} (#{stage["failures"]})"
      end
    end.compact.join(", ")

    puts "#{build_number}: Failed in #{failure_summary} at #{build["timestamp"]}"
    build["stages"].each do |job,stage|
      stage["runs"].values.each do |run|
        unless run["result"].nil? || run["result"] == "SUCCESS"
#          puts "- #{run["url"]}"
        end
      end
    end
  end
end
