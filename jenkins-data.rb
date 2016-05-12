require_relative "jenkins_data"
require "pp"

options = {}
options[:job] = ARGV[0] if ARGV[0]

JenkinsData.new(options).refresh
