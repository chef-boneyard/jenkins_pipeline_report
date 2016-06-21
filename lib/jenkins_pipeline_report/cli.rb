require "optparse"
require "uri"
require "pathname"
require_relative "summary_cache"
require_relative "cli_query"
require_relative "jenkins/cache"

module JenkinsPipelineReport
  module Cli
    def self.options
      @options ||= { identity_file: "~/.ssh/id_rsa" }
    end

    def self.logger
      @logger ||= begin
        logger = Logger.new(STDERR)
        logger.level = Logger::DEBUG
        logger
      end
    end

    def self.jenkins_cache
      @jenkins_cache ||= Jenkins::Cache.new("cache", identity_file: options[:identity_file])
    end

    def self.summary_cache(job_url)
      SummaryCache.new("reports", logger: logger, job_url: job_url)
    end

    def self.parse_url(url)
      parts = URI(url).path.split("/")
      raise "#{url} is not a job URL!" unless parts.size >= 3 && parts[1] == "job"
      job_url = URI(url)
      job_url.path = File.join(*parts[0..2])
      if parts.size > 3
        build_number = parts[3].to_i
      end
      [ job_url, build_number ]
    end

    def self.builds(url)
      job_url, build_number = parse_url(url)
      summary_cache(job_url).builds(
        build_number,
        local: options[:local],
        force_refresh_runs: options[:force_refresh_runs],
        force_refresh_logs: options[:force_refresh_logs],
        force_reprocess_logs: options[:force_reprocess_logs],
        force_resummarize: options[:force_resummarize]
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
        opts.on("--identity-file=FILE", "Identity file to talk to Jenkins. Default: ~/.ssh/id_rsa") do |v|
          options[:identity_file] = "~/.ssh/id_rsa"
        end
        opts.on("--where KEY=VALUE", "Only pick builds with KEY (a.b.c) equal to value") do |v|
          if options[:where]
            options[:where] = CliQuery.and(options[:where], CliQuery.parse(v))
          else
            options[:where] = CliQuery.parse(v)
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
        opts.on("--[no-]force-resummarize", "Whether to recalculate all failure summaries regardless of whether they've been calculated before (default: false).") do |v|
          options[:force_recalculate] = v
        end
      end.parse!
      # Default these to force
      %w{force_refresh_runs force_refresh_logs force_reprocess_logs}.each do |key|
        options[key.to_sym] = options[:force] if options[:force] && !options.has_key?(key.to_sym)
      end
    end
  end
end
