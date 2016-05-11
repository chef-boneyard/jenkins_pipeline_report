require "pp"
require "jenkins_api_client"
require_relative "jenkins_pipeline"

options = {
  server_url: "http://manhattan.ci.chef.co",
  identity_file: "~/.ssh/id_rsa",
  log_level: Logger::WARN,
  pipeline: ARGV[0] || "chef-build",
}
puts "Config:"
pp options

client = JenkinsApi::Client.new(options)
puts "Jenkins at #{options[:server_url]} #{client.exec_cli("version")}"

last_message = nil

jenkins = JenkinsPipeline.new(client, options[:pipeline])
jenkins.builds.each do |build|
  timestamp = Time.at(build["timestamp"].to_f / 1000.0).to_datetime
  prefix = "[#{build["job"]} #{build["number"]} #{timestamp.strftime("%m/%d/%Y")}]"
  unsuccessful_builds = jenkins.downstream_builds(build).select { |b| b["result"] != "SUCCESS" }
  if unsuccessful_builds.any? { |b| b["result"].nil? }
    message = "In Progress"
  elsif unsuccessful_builds.any?
    message = "Failed"
  else
    message = "Succeeded"
  end
  builds = unsuccessful_builds.map do |unsuccessful|
    runs = jenkins.runs(unsuccessful)
    runs.select! { |run| !run["result"].nil? && run["result"] != "SUCCESS" }
    runs = runs.map { |run| jenkins.classify_run(run) }.sort
    "#{unsuccessful["job"]} #{runs.join(",")}"
  end.sort.uniq.join("; ")
  message << " (#{builds})" if builds != ""

  # Separate groups of failures
  unless last_message.nil? || last_message == message
    puts ""
  end
  puts "#{prefix} #{message}"
  last_message = message
end
