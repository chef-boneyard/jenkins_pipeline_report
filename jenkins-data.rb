require_relative "jenkins_cli"

JenkinsCli.logger.level = Logger::DEBUG

JenkinsCli.parse_options do |opts|
  opts.banner = <<-EOM
    USAGE: ruby #{File.basename(__FILE__)} JOB_URL ...

    Download and cache Jenkins data.

    ruby #{File.basename(__FILE__)} https://manhattan.ci.chef.co/job/chef-trigger-release https://wilson.ci.chef.co/job/chef-server-12-trigger-release

    You must upload your public SSH key to your Jenkins server from ~/.ssh/id_rsa.
  EOM
end

ARGV.each do |job_url|
  # Handles the refresh
  JenkinsCli.builds(job_url)
end
