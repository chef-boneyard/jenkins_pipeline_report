require_relative "log_extractor"
require_relative "acceptance_extractor"
require_relative "timing_extractor"
require_relative "failure_extractor"

module JenkinsPipelineReport
  module Report
    #
    # Generates a report for a build stage.
    #
    # One of these is created for the most recent retry of each stage:
    # - http://my.jenkins.com/job/first-stage/48
    # - http://my.jenkins.com/job/second-stage/23
    # etc.
    #
    class Stage
      #
      # The parent build report.
      #
      # @return [Report::Build] The parent build report.
      #
      attr_reader :build_report

      #
      # The Jenkins build most recently run for this stage.
      #
      # @return [Jenkins::Build] The Jenkins build for this stage.
      #
      attr_reader :build

      #
      # Create a new stage report generator.
      #
      # @param build_report [Report::Build] The parent build report.
      # @param build [Jenkins::Build] The Jenkins build for this stage.
      #
      def initialize(build_report, build)
        @build_report = build_report
        @build = build
      end

      #
      # Generate the report.
      #
      # @return [Hash] The report.
      #
      def generate_report
        Cli.logger.debug("- Generating stage report for #{build.url} ...")
        report = {
          "result" => build.result || "IN PROGRESS",
          "url" => build.url,
          "duration" => build_report.format_duration(build.duration),
          "delay" => build_report.format_duration(generate_delay),
          # TODO runs and processes
          # TODO failures, failure types, aggregation
          # TODO log excerpts
        }
        process_logs(report)
        report.reject! { |key,value| value.nil? }
        report
      end

      def console_text_lines
        @console_text_lines ||= build.console_text.lines
      end

      def generate_change
        result = {
          "version" => build.parameters["OMNIBUS_BUILD_VERSION"],
          "git_ref" => build.parameters["GIT_REF"],
          "delivery_change" => build.parameters["DELIVERY_CHANGE"],
          "delivery_sha" => build.parameters["DELIVERY_SHA"],
          "git_commit" => build.parameters["GIT_COMMIT"],
        }
        result.reject! { |key,value| value.nil? || value.empty? }
      end

      def stage_path
        # Get rid of "job" from the top of the path. Generally the result will
        # just be `name`, but sometimes it'll be a multipath, so it pays to be
        # correct.
        Pathname(build.job.path).relative_path_from(Pathname("/job"))
      end

      private

      def generate_delay
        upstream_end = build.upstreams.map { |upstream| upstream.end_timestamp }.compact.max
        build.timestamp - upstream_end if upstream_end
      end

      def process_logs(report)
        LogExtractor.new(self, report).extract
        AcceptanceExtractor.new(self, report).extract
        TimingExtractor.new(self, report).extract
        FailureExtractor.new(self, report).extract
      end

    end
  end
end
