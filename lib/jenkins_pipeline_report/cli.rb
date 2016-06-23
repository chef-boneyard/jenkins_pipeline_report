require "optparse"
require "uri"
require "pathname"
require_relative "cli/query"
require_relative "jenkins/cache"
require_relative "report/report_cache"

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

    def self.report_cache
      @reports ||= Report::ReportCache.new(options[:reports_directory])
    end

    def self.jenkins_cache
      @jenkins_cache ||= Jenkins::Cache.new(options[:cache_directory], identity_file: options[:identity_file])
    end

    def self.builds(*args, refresh_jenkins: true)
      args.flat_map do |arg|
        arg = jenkins_cache.jenkins_object(arg) if arg.is_a?(String)

        if refresh_jenkins
          arg.refresh(pipeline: true, invalidate: true)
        end

        case arg
        when Jenkins::Build
          triggers = arg.triggers
        else
          triggers = arg.builds.select { |build| build.upstreams.empty? }
        end
        triggers.map { |trigger| report_cache.report(trigger) }
      end
    end

    def self.jenkins_args
      if ARGV.any?
        ARGV.map { |arg| jenkins_cache.jenkins_object(url) }
      else
        [ jenkins_cache ]
      end
    end

    def self.parse_options
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
            options[:where] = Cli::Query.and(options[:where], Cli::Query.parse(v))
          else
            options[:where] = Cli::Query.parse(v)
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
        opts.on("--cache-directory=PATH", "The cache directory for Jenkins data. Defaults to <reports directory>/.jenkins_cache.") do |v|
          options[:cache_directory] = v
        end
        opts.on("--reports-directory=PATH", "The reports directory Defaults to ./reports.") do |v|
          options[:reports_directory] = v
        end
      end.parse!
      # Default these to force
      %w{force_refresh_runs force_refresh_logs force_reprocess_logs}.each do |key|
        options[key.to_sym] = options[:force] if options[:force] && !options.has_key?(key.to_sym)
      end
      # Default cache-directory to cache
      options[:reports_directory] ||= "reports"
      options[:cache_directory] ||= File.join(options[:reports_directory], ".jenkins_cache")
    end
  end
end
