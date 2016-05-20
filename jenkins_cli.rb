require "optparse"
require_relative "jenkins_data"
require "pp"

module JenkinsCli
  def self.options
    @options ||= { refresh: true }
  end

  def self.builds(job_url)
    jenkins = JenkinsData.new(job_url: job_url)
    if options[:refresh]
      builds = jenkins.refresh(
        force_refresh_runs: options[:force_refresh_runs],
        force_refresh_logs: options[:force_refresh_logs],
        force_reprocess_logs: options[:force_reprocess_logs]
      )
    else
      jenkins.load
    end
  end

  def self.parse_options
    OptionParser.new do |opts|
      yield opts

      opts.on("--[no-]refresh", "Whether to refresh data to latest (default: true).") do |v|
        options[:refresh] = v
      end
      opts.on("--[no-]force", "Whether to refresh all data regardless of whether they've been fetched before (default: false).") do |v|
        options[:force] = v
      end
      opts.on("--[no-]force-refresh-runs", "Whether to refresh run data for all runs regardless of whether they've been fetched before (default: false).") do |v|
        options[:force_refresh_runs] = v
      end
      opts.on("--[no-]force-refresh-logs", "Whether to re-download logs for all runs (default: false).") do |v|
        options[:force_refresh_logs] = v
      end
      opts.on("--[no-]force-reprocess-logs", "Whether to reprocess old logs for things like omnibus timing (default: false).") do |v|
        options[:force_reprocess_logs] = v ? v : nil
      end
    end.parse!
    # Default these to force
    %w{force_refresh_runs force_refresh_logs force_reprocess_logs}.each do |key|
      options[key.to_sym] = options[:force] if options[:force] && !options.has_key?(key.to_sym)
    end
  end
end
