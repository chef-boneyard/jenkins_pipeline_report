require_relative "build_report"

module JenkinsPipelineReport
  module Report
    #
    # Represents the directory where reports are generated. This class takes care
    # of generating new reports and refreshing old ones when necessary.
    #
    # Directories look like `reports/my.jenkins.com/job/job-name/1.yaml`.
    #
    class ReportCache
      #
      # The path where reports will be generated.
      #
      # @return [String] The path to the reports directory.
      #
      attr_reader :reports_directory

      #
      # The logger to log to.
      #
      # @return [Logger] The logger to log to.
      #
      attr_reader :logger

      #
      # Whether to analyze the logs of successful builds.
      #
      # @return [Boolean] Whether to analyze the logs of successful builds.
      #
      def analyze_successful_logs?
        @analyze_successful_logs
      end

      #
      # Create a new report generator cache.
      #
      # @param reports_directory [String] The path to the reports directory.
      # @param analyze_successful_logs [Boolean] Whether to analyze logs of successful builds.
      #
      def initialize(reports_directory: nil, logger: Cli.logger, analyze_successful_logs: false)
        @logger = logger
        @reports_directory = reports_directory
        @analyze_successful_logs = analyze_successful_logs
      end

      #
      # Get the report for the given build.
      #
      def report(build)
        BuildReport.new(self, build)
      end

      def delete_cache(url)
        path = report_path(url)
        if File.exist?(path)
          logger.info("Deleting #{path} ...")
          File.delete(path)
        end
      end

      def read_cache(url)
        path = report_path(url)
        if File.exist?(path)
          logger.debug("Reading #{path} ...")
          Psych.load_file(path)
        end
      end

      def write_cache(url, value)
        path = report_path(url)
        logger.debug("Writing #{path} ...")
        FileUtils.mkdir_p(File.dirname(path))
        IO.write(path, Psych.dump(value))
        value
      end

      def report_path(url, type: :yaml)
        uri = URI(url)
        if uri.host
          filename = File.join(uri.host, uri.path)
        else
          filename = uri.path
        end
        filename.sub!(/\/+$/, "") # remove trailing slashes
        filename = "#{filename}.#{type}" if type
        filename.gsub!(/[^\w\.-_\/\\]/, "-") # strip bad filename characters
        File.join(reports_directory, filename)
      end
    end
  end
end
