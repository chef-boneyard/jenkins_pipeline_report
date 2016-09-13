require "optparse"
require "uri"
require "pathname"
require_relative "cli/query"
require_relative "jenkins/cache"
require_relative "report/report_cache"

module JenkinsPipelineReport
  module Cli
    def self.options
      @options ||= { identity_file: "~/.ssh/id_rsa", analyze_successful_logs: true }
    end

    def self.logger
      @logger ||= begin
        logger = Logger.new(STDERR)
        logger.level = Logger::DEBUG
        logger
      end
    end

    def self.report_cache
      @reports ||= Report::ReportCache.new(
        reports_directory: options[:reports_directory],
        analyze_successful_logs: options[:analyze_successful_logs]
      )
    end

    def self.jenkins_cache
      @jenkins_cache ||= Jenkins::Cache.new(
        cache_directory: options[:cache_directory],
        client_options: { identity_file: options[:identity_file] }
      )
    end

    def self.builds(*args, refresh_jenkins: true)
      # Anything we pull on now will fetch rather than load locally
      jenkins_cache.invalidate if refresh_jenkins

      args = [ jenkins_cache ] if args.empty?

      args.flat_map do |arg|
        arg = jenkins_cache.jenkins_object(arg) if arg.is_a?(String)

        if refresh_jenkins
          case arg
          when Jenkins::Build
            # We need to refresh the downstream list of jobs to look for new
            # stages and retries; hitting the downstreams will do that.
            arg.job.all_downstreams.each { |job| job.builds }
          when Jenkins::Job
            # We need to refresh the list of jobs
            arg.all_downstreams.each { |job| job.builds }
          end
        end

        case arg
        when Jenkins::Build
          triggers = arg.triggers
        else
          triggers = arg.builds.select { |build| build.upstreams.empty? }
        end

        triggers = triggers.select { |trigger| options[:where] === trigger } if options[:where]
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
        opts.on("--[no-]analyze-successful-logs", "Whether to analyze the logs of successful runs (default: true).") do |v|
          options[:analyze_successful_logs] = v
        end
        opts.on("--cache-directory=PATH", "The cache directory for Jenkins data. Defaults to ./.jenkins_cache.") do |v|
          options[:cache_directory] = v
        end
        opts.on("--reports-directory=PATH", "The reports directory Defaults to ./reports.") do |v|
          options[:reports_directory] = v
        end
      end.parse!
      # Default cache-directory to cache
      options[:reports_directory] ||= "reports"
      options[:cache_directory] ||= ".jenkins_cache"
    end
  end
end
