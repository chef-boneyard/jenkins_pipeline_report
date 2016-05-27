require "optparse"
require_relative "jenkins_data"
require_relative "jenkins_query"
require "pp"

module JenkinsCli
  def self.options
    @options ||= {}
  end

  def self.logger
    @logger ||= begin
      logger = Logger.new(STDERR)
      logger.level = Logger::DEBUG
      logger
    end
  end

  def self.jenkins_data(job_url)
    JenkinsData.new("reports", logger: logger, job_url: job_url)
  end

  def self.builds(job_url)
    jenkins_data(job_url).builds(
      local: options[:local],
      force_refresh_runs: options[:force_refresh_runs],
      force_refresh_logs: options[:force_refresh_logs],
      force_reprocess_logs: options[:force_reprocess_logs]
    ) do |build|
      if options[:where]
        options[:where] === build
      else
        true
      end
    end
  end

  def self.parse_options()
    OptionParser.new do |opts|
      yield opts

      opts.on("-l=LEVEL", "--log-level=LEVEL", "Log level (debug,info,warn,error,fatal).") do |v|
        logger.level = Logger.const_get(v.upcase)
      end
      opts.on("--where KEY=VALUE", "Only pick builds with KEY (a.b.c) equal to value") do |v|
        if options[:where]
          options[:where] = JenkinsQuery.and(options[:where], JenkinsQuery.parse(v))
        else
          options[:where] = JenkinsQuery.parse(v)
        end
      end
      opts.on("--[no-]local", "Whether to get the list of builds locally (default: false).") do |v|
        options[:local] = v
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
