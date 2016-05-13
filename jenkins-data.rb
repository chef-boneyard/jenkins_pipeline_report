require_relative "jenkins_data"
require "pp"

if ARGV.empty?
  puts <<-EOM
USAGE: ruby jenkins-data.rb JOB_URL ...

Download and cache Jenkins data.

ruby jenkins-data.rb https://manhattan.ci.chef.co/job/chef-trigger-release https://wilson.ci.chef.co/job/chef-server-12-trigger-release

You must upload your public SSH key to your Jenkins server from ~/.ssh/id_rsa.
  EOM
end

ARGV.each do |job_url|
  JenkinsData.new(job_url: job_url).refresh
end
