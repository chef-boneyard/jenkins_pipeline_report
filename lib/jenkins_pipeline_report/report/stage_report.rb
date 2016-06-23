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
    class StageReport
      #
      # The parent build report.
      #
      # @return [Report::Build] The parent build report.
      #
      attr_reader :build_report

      #
      # The retries involved in this build stage, from oldest to newest.
      #
      # @return [Array<Jenkins::Build>] The retries involved in this build stage.
      #
      attr_reader :retries

      #
      # Create a new stage report generator.
      #
      # @param build_report [Report::Build] The parent build report.
      # @param build [Jenkins::Build] The Jenkins build for this stage.
      #
      def initialize(build_report, retries)
        @build_report = build_report
        @retries = retries
        @build = build
      end

      #
      # The Jenkins build most recently run for this stage.
      #
      # @return [Jenkins::Build] The Jenkins build for this stage.
      #
      def build
        retries.last
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
          "active_duration" => build_report.format_duration(generate_active_duration),
          "retries" => generate_retries,
          "queue_delay" => build_report.format_duration(generate_queue_delay),
          "retry_delay" => build_report.format_duration(generate_retry_delay),
          "duration" => build_report.format_duration(generate_duration),
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

      def stage_path
        # Get rid of "job" from the top of the path. Generally the result will
        # just be `name`, but sometimes it'll be a multipath, so it pays to be
        # correct.
        Pathname(build.job.path).relative_path_from(Pathname("/job")).to_s
      end

      def generate_change
        result = {
          "version" => build.parameters["OMNIBUS_BUILD_VERSION"],
          "git_commit" => build.parameters["GIT_COMMIT"],
        }
        result.reject! { |key,value| value.nil? || value == "" }
        result
      end

      def generate_duration
        build.end_timestamp - retries.first.timestamp if build.end_timestamp
      end

      def generate_active_duration
        build.duration
      end

      def generate_queue_delay
        previous_stage_end = retries.first.upstreams.map { |upstream| upstream.end_timestamp }.compact.max
        return retries.first.timestamp - previous_stage_end if previous_stage_end
      end

      def generate_retry_delay
        result = build.timestamp - retries.first.timestamp
        return result unless result == 0
      end

      private

      def generate_retries
        return retries.size - 1 if retries.size > 1
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