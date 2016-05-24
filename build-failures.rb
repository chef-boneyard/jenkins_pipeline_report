require_relative "jenkins_cli"

options = {}
JenkinsCli.parse_options do |opts|
  opts.banner = <<-EOM
    USAGE: ruby #{File.basename(__FILE__)} JOB_URL ...

    Create a report of build failures.

    ruby #{File.basename(__FILE__)} https://manhattan.ci.chef.co/job/chef-trigger-release https://wilson.ci.chef.co/job/chef-server-12-trigger-release

    You must upload your public SSH key to your Jenkins server from ~/.ssh/id_rsa.
  EOM

  opts.on("--[no-]urls", "Whether to show the URLs for all failing jobs (default: false).") do |v|
    options[:urls] = v
  end
end

ARGV.each do |job_url|
  job = File.basename(job_url)
  builds = JenkinsCli.builds(job_url)
  builds.each do |build|
    if JenkinsData.failed?(build)
      build_number = File.basename(build["stages"][job]["url"])
      failure_summary = build["stages"].map do |name,stage|
        if JenkinsData.failed?(stage)
          name
        end
      end.compact.join(", ")

      puts "#{build_number}: #{build["result"].downcase.capitalize} in #{failure_summary} at #{build["timestamp"]}"
      build["stages"].each do |job,stage|
        if stage["failures"]
          failures = stage["failures"].sort_by { |cause,failures| cause }
          failures.each do |cause, failingRuns|
            puts "  * #{cause}: #{failingRuns}"
          end
        end
      end

      if options[:urls]
        printed_anything = false
        build["stages"].each do |job,stage|
          if JenkinsData.failed?(stage)
            printed_anything = true
            puts "  - #{stage["result"].downcase}: #{stage["url"]}"
          end
          stage["runs"].values.each do |run|
            if JenkinsData.failed?(run)
              printed_anything = true
              puts "  - run #{run["result"].downcase}: #{run["url"]}"
            end
          end
        end
        # If we didn't find an actual failed stage or run, print something anyway
        unless printed_anything
          stage = build["stages"].values.last
          puts "  - #{stage["result"].downcase}: #{stage["url"]}"
          stage["runs"].values.each do |run|
            puts "  - run #{run["result"].downcase}: #{run["url"]}"
          end
        end
      end
    end
  end
end
