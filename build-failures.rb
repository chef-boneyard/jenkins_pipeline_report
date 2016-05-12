require "pp"
require "jenkins_api_client"
require_relative "jenkins_pipeline"

options = {}
options[:job] = ARGV[0] if ARGV[0]


last_message = nil
builds = JenkinsData.new(options).refresh
builds.each do |build|
  terminal_build = build.last

  prefix = "[#{build["job"]} #{build["number"]} #{build["timestamp"].strftime("%m/%d/%Y")}]"
  case terminal_build["result"]
  when nil
    message = "In Progress"
  when "SUCCESS"
    message = "Succeeded"
  else
    message = "Failed"
    failed_runs = jenkins.runs(terminal_build)
    failed_runs.select! { |run| !run["result"].nil? && run["result"] != "SUCCESS" }
    failed_runs = runs.map { |run| run["configuration_summary"] }.sort
    message << "Failed in #{terminal_build["job"]} #{runs.join(",")}"
  end

  # Separate groups of failures and successes
  unless last_message.nil? || last_message == message
    puts ""
  end
  puts "#{prefix} #{message}"
  last_message = message
end
