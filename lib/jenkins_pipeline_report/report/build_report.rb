require "pathname"
require_relative "stage_report"

module JenkinsPipelineReport
  module Report
    class BuildReport
      attr_reader :report_cache
      attr_reader :trigger

      def initialize(report_cache, trigger)
        @report_cache = report_cache
        @trigger = trigger
      end

      def analyze_successful_logs?
        report_cache.analyze_successful_logs?
      end

      def refresh
        # See if we already have the report or not.
        if needs_update?
          @report = write_cache(generate_report)
        end
        # `report` will generate the report if we don't have it.
        report
      end

      def report
        @report ||= read_cache || write_cache(generate_report)
      end

      def report?
        @report ||= read_cache
      end

      def needs_update?
        report = report?
        return true unless report
        return true if report["result"] == "IN PROGRESS"
        return true if analyze_successful_logs? && report["successful_logs_analyzed"] == false
        # Handle build retries
        return true unless report_has_all_stages?(report)
        return true unless stage_reports.any? { |stage| stage.needs_update? }
        # TODO if runs are retries or processes happen, regenerate
      end

      def format_duration(duration)
        BuildReport.format_duration(duration)
      end

      def format_datetime(datetime)
        BuildReport.format_datetime(datetime)
      end

      def self.format_datetime(datetime)
        datetime.to_s
      end

      def self.format_duration(duration)
        return nil if duration.nil?
        if duration < 0
          duration = duration.abs
          negative = true
        end
        minutes, seconds = duration.divmod(60)
        hours, minutes = minutes.divmod(60)
        seconds = seconds.to_i
        result = negative ? "-" : ""
        result << "#{hours}h" if hours > 0
        result << "#{minutes}m" if minutes > 0
        result << "#{seconds}s" if seconds > 0
        result = "0s" if result == ""
        result
      end

      private

      def report_has_all_stages?(report)
        report_stage_urls = report["stages"].map { |name, stage| stage["url"] }.sort
        stage_urls = stage_reports.map { |stage| stage.build.url }.sort
        report_stage_urls == stage_urls
      end

      def generate_report
        Cli.logger.info("Generating build report for #{trigger.url} ...")
        report = {
          "result" => generate_result,
          "url" => trigger.url,
          "timestamp" => format_datetime(trigger.timestamp),
          "duration" => format_duration(generate_duration),
          "triggered_by" => trigger.triggered_by.id,
          "active_duration" => format_duration(generate_active_duration),
          "queue_delays" => format_duration(generate_queue_delays),
          "retry_delays" => format_duration(generate_retry_delays),
          "parameters" => trigger.parameters,
          "change" => generate_change,
          "stages" => generate_stage_reports,
        }
        report["successful_logs_analyzed"] = false unless analyze_successful_logs?
        report.reject! { |key,value| value.nil? }
        report
      end

      def generate_stage_reports
        result = {}
        stage_reports.reverse_each do |stage|
          result[stage.stage_path] = stage.refresh
        end
        result
      end

      def generate_duration
        stage_end_times = stage_reports.map { |stage| stage.build.end_timestamp }.compact
        stage_end_times.max - trigger.timestamp
      end

      #
      # List of build stage reports.
      #
      # @return [Array<Stage>] List of build stage reports.
      #
      def stage_reports
        @stage_reports ||= calculate_stages(trigger)
      end

      #
      # Overall result of the build.
      #
      # @return [String] `nil` if any stage is in progress. "FAILED" if
      #   nothing is in progress and something failed. "SUCCESS" otherwise.
      #
      def generate_result
        result = "SUCCESS"
        stage_reports.each do |stage|
          case stage.build.result
          # If it's IN PROGRESS, then no other status overrides that.
          when nil
            return "IN PROGRESS"

          # It's SUCCESS by default, and SUCCESS never overrides failure or in progress.
          when "SUCCESS"

          # Mark FAILURE unless we get a more specific result (like ABORTED)
          # elsewhere.
          when "FAILURE"
            result = "FAILURE" unless !%w{SUCCESS FAILURE}.include?(stage.build.result)

          else
            # More specific result like ABORTED
            result = stage.build.result
          end
        end
        result
      end

      #
      # Change data (git commit, delivery change / sha).
      #
      def generate_change
        change = {}
        stage_reports.map do |stage|
          change.merge!(stage.generate_change) do |key, old_value, new_value|
            if old_value != new_value
              raise "More than one #{key} found in stages! One build had #{key}=#{old_value}, another had #{key}=#{new_value}"
            end
            old_value
          end
        end
        change
      end

      def generate_queue_delays
        sum = 0
        stage_reports.each do |stage|
          delay = stage.generate_queue_delay
          sum += delay if delay
        end
        return sum unless sum == 0
      end

      def generate_retry_delays
        sum = 0
        stage_reports.each do |stage|
          delay = stage.generate_retry_delay
          sum += delay if delay
        end
        return sum unless sum == 0
      end

      def generate_active_duration
        sum = 0
        stage_reports.each do |stage|
          duration = stage.build.duration
          sum += duration if duration
        end
        sum
      end

      #
      # Cache operations
      #
      def delete_cache
        report_cache.delete_cache(trigger.url)
      end

      def read_cache
        report_cache.read_cache(trigger.url)
      end

      def write_cache(value)
        report_cache.write_cache(trigger.url, value)
      end

      def calculate_stages(build)
        retries = build.retries
        stage = StageReport.new(self, retries)
        next_stages = {}
        stage.build.downstreams.each do |downstream|
          next_stages[downstream.job] ||= calculate_stages(downstream)
        end
        [ stage, *next_stages.values.flatten(1) ].uniq
      end
    end
  end
end
