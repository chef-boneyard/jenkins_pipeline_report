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

      def refresh_report
        # See if we already have the report or not.
        @report ||= read_cache
        if @report
          # Regenerate the report if it's in progress.
          if @report["result"] == "IN PROGRESS" || !report_has_all_stages?
            @report = write_cache(generate_report)
          end
        end
        # `report` will generate the report if we don't have it.
        report
      end

      def report
        @report ||= read_cache || write_cache(generate_report)
      end

      def format_datetime(datetime)
        datetime.to_s
      end

      def format_duration(duration)
        return nil if duration.nil?
        minutes, seconds = duration.divmod(60)
        hours, minutes = minutes.divmod(60)
        seconds = seconds.to_i
        result = ""
        result << "#{hours}h" if hours > 0
        result << "#{minutes}m" if minutes > 0
        result << "#{seconds}s" if seconds > 0
        result = "0s" if result == ""
        result
      end

      private

      def report_has_all_stages?
        report_stage_urls = report["stages"].map { |name, stage| stage["url"] }.sort
        stage_urls = stages.map { |stage| stage.build.url }.sort
        report_stage_urls == stage_urls
      end

      def generate_report
        Cli.logger.debug("Generating build report for #{trigger.url} ...")
        report = {
          "result" => generate_result,
          "url" => trigger.url,
          "timestamp" => format_datetime(trigger.timestamp),
          "duration" => format_duration(generate_duration),
          "active_duration" => format_duration(generate_active_duration),
          "queue_delays" => format_duration(generate_queue_delays),
          "retry_delays" => format_duration(generate_retry_delays),
          "triggered_by" => generate_triggered_by,
          "parameters" => trigger.parameters,
          "change" => generate_change,
          "stages" => generate_stages,
        }
        report.reject! { |key,value| value.nil? }
        report
      end

      def generate_stages
        result = {}
        stages.reverse_each do |stage|
          # Don't regenereate completed stages
          existing_stage = @data["stages"][stage.stage_path] if @data && @data["stages"]
          if existing_stage && existing_stage["result"] != "IN PROGRESS"
            Cli.logger.debug("- Kept build report for #{stage.build.url} ...")
            result[stage.stage_path] = existing_stage
          else
            result[stage.stage_path] = stage.generate_report
          end
        end
        result
      end

      def generate_duration
        stage_end_times = stages.map { |stage| stage.build.end_timestamp }.compact
        stage_end_times.max - trigger.timestamp
      end

      #
      # List of build stage reports.
      #
      # @return [Array<Stage>] List of build stage reports.
      #
      def stages
        @stages ||= calculate_stages(trigger)
      end

      #
      # User who started the job
      #
      def generate_triggered_by
        if trigger.data["actions"]
          trigger.data["actions"].each do |action|
            next unless action["causes"]
            action["causes"].each do |cause|
              return cause["userId"] if cause["userId"]
            end
          end
        end
        nil
      end

      #
      # Overall result of the build.
      #
      # @return [String] `nil` if any stage is in progress. "FAILED" if
      #   nothing is in progress and something failed. "SUCCESS" otherwise.
      #
      def generate_result
        result = "SUCCESS"
        stages.each do |stage|
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
        stages.map do |stage|
          change.merge(stage.generate_change) do |key, old_value, new_value|
            if old_value != new_value
              raise "More than one #{key} found in stages! One build had #{key}=#{old_value}, another had #{key}=#{new_value}"
            end
          end
        end
        change
      end

      def generate_queue_delays
        sum = 0
        stages.each do |stage|
          delay = stage.generate_queue_delay
          sum += delay if delay
        end
        return sum unless sum == 0
      end

      def generate_retry_delays
        sum = 0
        stages.each do |stage|
          delay = stage.generate_retry_delay
          sum += delay if delay
        end
        return sum unless sum == 0
      end

      def generate_active_duration
        sum = 0
        stages.each do |stage|
          duration = stage.generate_active_duration
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
