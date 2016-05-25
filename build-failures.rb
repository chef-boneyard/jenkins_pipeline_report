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

builds = ARGV.flat_map do |job_url|
  JenkinsCli.builds(job_url)
end.sort_by { |build| build["timestamp"] }.reverse

def report_summary(builds)
  puts "SUMMARY"
  failure_types = {}
  builds.flat_map do |build|
    if build["failures"]
      build["failures"].keys.each do |failure|
        # Leave the build job out of it
        failure = failure.split(" ", 2)[1]
        failure_types[failure] ||= 0
        failure_types[failure] += 1
      end
    elsif JenkinsData.failed?(build)
      failure_types["unknown"] ||= 0
      failure_types["unknown"] += 1
    else
      failure_types["success"] ||= 0
      failure_types["success"] += 1
    end
  end

  puts "total: #{builds.size}"
  failed_builds = builds.select { |build| JenkinsData.failed?(build) }
  puts "failed: #{failed_builds.size} (#{(failed_builds.size/builds.size.to_f*100.0).round(1)}%)"

  # Reverse sort
  failure_types = failure_types.to_a.sort { |(a_name,a_total),(b_name,b_total)|
    result = b_total <=> a_total
    result = a_name <=> b_name if result == 0
    result
  }
  failure_types.each do |key, value|
    percent = value.to_f/failed_builds.size.to_f*100.0
    puts "#{key}: #{value} (#{percent.round(1)}% of failures)"
  end
end

report_summary(builds)

def report_build_failures(builds, urls: false)
  puts ""
  puts "BY BUILD"
  builds.each do |build|
    if JenkinsData.failed?(build)
      job = File.basename(File.dirname(build["url"]))
      build_number = File.basename(build["url"])
      failure_summary = build["stages"].map do |name,stage|
        if JenkinsData.failed?(stage)
          name
        end
      end.compact.join(", ")

      if ARGV.size == 1
        prefix = build_number
      else
        if urls
          prefix = build["url"]
        else
          prefix = "#{job}/#{build_number}"
        end
      end

      puts "#{prefix}: #{build["result"].downcase.capitalize} in #{failure_summary} at #{build["timestamp"]}"
      build["stages"].each do |job,stage|
        if stage["failures"]
          failures = stage["failures"].sort_by { |cause,failures| cause }
          failures.each do |cause, failingRuns|
            puts "  * #{cause}: #{failingRuns}"
          end
        end
      end

      if urls
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

report_build_failures(builds, **options)
