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

      def report_cache
        build_report.report_cache
      end

      #
      # The build we're generating a report for.
      #
      # @return [Jenkins::Build] The build we're generating a report for.
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

      def refresh
        # See if we already have the report or not.
        if needs_update?
          @report = write_cache(generate_report)
        end
        # `report` will generate the report if we don't have it.
        report
      end

      #
      # Generate the report.
      #
      # @param existing_report [Hash] The existing report (if any).
      #
      # @return [Hash] The report.
      #
      def generate_report
        report_cache.logger.debug("- Generating stage report for #{build.url} ...")
        report = {
          "result" => build.result || "IN PROGRESS",
          "failure_category" => nil,
          "failure_cause" => nil,
          "failed_in" => nil,
          "timestamp" => build_report.format_datetime(build.timestamp),
          "url" => build.url,
          "trigger_url" => build.triggers.first.url,
          "duration" => build_report.format_duration(generate_duration),
          "active_duration" => build_report.format_duration(generate_active_duration),
          "retries" => generate_retries,
          "retry_delay" => build_report.format_duration(generate_retry_delay),
          "queue_delay" => build_report.format_duration(generate_queue_delay),
          "logs" => nil,
          "steps" => nil,
          # TODO runs and processes
          # TODO failures, failure types, aggregation
          # TODO log excerpts
        }
        report["logs_analyzed"] = false unless process_logs(report)
        report["runs"] = generate_run_reports
        generate_failure_cause(report)
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

      def run_reports
        @run_reports ||= {}
        build.runs.each do |run|
          run_report(run.url)
        end
        @run_reports.values
      end

      def generate_run_reports
        # TODO this won't refresh retries of any runs, but we don't do that right now, so we're ok
        reports = {}
        run_reports.sort_by do |run_report|
          result_score = case run_report.build.result
          when nil
            3
          when "SUCCESS"
            2
          else
            1
          end
          [ result_score, run_report.build.url ]
        end.each do |run_report|
          report = run_report.refresh.dup
          report.delete("timestamp")
          report.delete("trigger_url")
          report.delete("logs")
          report.delete("steps")
          reports[run_report.stage_path] = report
        end
        reports = nil if reports.empty?
        reports
      end

      def generate_failure_cause(report)
        if report["runs"]
          configurations = report["runs"].keys
          # Group the runs by failure cause
          failed_runs = report["runs"].select { |k,run| run["result"] != "IN PROGRESS" && run["result"] != "SUCCESS" }
          if failed_runs.any?
            by_category = failed_runs.group_by { |configuration,run| run["failure_category"] }
            report["failure_category"] = by_category.to_a.sort_by { |k,v| v.size }.last[0]
            by_cause = failed_runs.group_by { |configuration,run| run["failure_cause"] }
            report["failure_cause"] = by_cause.map do |failure_cause, runs|
              failed_configurations = runs.map { |configuration,run| configuration }
              failed_configurations = categorize_run_types(failed_configurations, configurations)
              "#{failure_cause}: #{failed_configurations.join(", ")}"
            end.join("; ")
          end
        end
        if report["result"] != "IN PROGRESS" && report["result"] != "SUCCESS"
          report["failure_category"] ||= "unknown"
          report["failure_cause"] ||= "unknown"
        end
      end

      def generate_change
        scm = build.job.data["scm"]
        if scm && scm["userRemoteConfigs"]
          github_urls = scm["userRemoteConfigs"].map { |remote| remote["url"] }
          if github_urls.size <= 1
            github_urls = github_urls.first
          end
        end

        result = {
          "git_remote" => github_urls,
          "git_commit" => build.parameters["GIT_COMMIT"],
          "project" => build.parameters["PROJECT"],
          "version" => build.parameters["OMNIBUS_BUILD_VERSION"],
        }
        result.reject! { |key,value| value.nil? || value == "" }
        result
      end

      def retries
        @retries ||= build.retries
      end

      def generate_duration
        build.end_timestamp - retries.first.timestamp if build.end_timestamp
      end

      def generate_active_duration
        build.duration unless retries.size == 1
      end

      def generate_queue_delay
        previous_stage_end = retries.first.upstreams.map { |upstream| upstream.end_timestamp }.compact.max
        if previous_stage_end
          queue_delay = retries.first.timestamp - previous_stage_end
          run_reports.each do |run_report|
            delay = run_report.generate_queue_delay
            if delay
              unless queue_delay && delay <= queue_delay
                queue_delay = delay
              end
            end
          end
        end
        queue_delay unless queue_delay && queue_delay < 10
      end

      def generate_retry_delay
        result = build.timestamp - retries.first.timestamp
        return result unless result == 0
      end

      def report
        @report ||= read_cache || write_cache(generate_report)
      end

      def report?
        @report ||= read_cache
      end

      def from_build_report
        report = build_report.report?
        stage_report ||= report && report["stages"] && report["stages"][stage_path]
        stage_report = nil unless stage_report && stage_report["url"] == build.url
        stage_report
      end

      #
      # Tell if this stage needs an update.
      #
      def needs_update?
        report = report?
        unless report
          report ||= from_build_report
          if report
            report["logs_analyzed"] = false if report["result"] == "SUCCESS" && !build_report.report["successful_logs_analyzed"]
          end
        end
        return true unless report
        return true if report["result"] == "IN PROGRESS"
        if report["logs_analyzed"] == false
          return true unless report["result"] == "SUCCESS"
          return true if build_report.analyze_successful_logs?
        end
        if report["runs"]
          return true if report["runs"].any? { |name, run| run.has_key?("logs") }
          return true if report["runs"].any? { |name, run| run_report(run["url"]).needs_update? }
        end
        # TODO we're assuming it's not possible to retry or add a run after the build has
        # completed here. If it is, we need to check the run reports (which is
        # expensive right now because we can't instantiate runs without loading
        # the build, and we don't want to load the build if we're just checking
        # whether we need to do work).
        # TODO check processes
      end

      private

      def run_report(url)
        @run_reports ||= {}
        @run_reports[url] ||= begin
          run = build.cache.build(url)
          RunReport.new(self, run)
        end
      end

      def generate_retries
        return retries.size - 1 if retries.size > 1
      end

      def process_logs(report)
        # We don't process in-progress logs
        return if build.result.nil?
        return if !build_report.analyze_successful_logs? && build.result == "SUCCESS"

        LogExtractor.new(self, report).extract
        AcceptanceExtractor.new(self, report).extract
        TimingExtractor.new(self, report).extract
        FailureExtractor.new(self, report).extract

        # Toss console text out of memory (if it was grabbed at all)
        @console_text_lines = nil

        true
      end

      # e.g. architecture=x86_64,platform=acceptance,project=chef,role=tester ->
      # -> chef-test, 243, acceptance
      def configuration_summary(configuration_str)
        #
        # Summarize the configuration for easy consumption
        #
        # configuration is a hash
        configuration = {}
        configuration_str.split(",").sort_by { |name, value| name }.each do |name_value|
          name, value = name_value.split("=", 2)
          configuration[name] = value
        end

        case configuration["role"]
        when "builder", "tester"
          configuration_summary = configuration["platform"]
          configuration_summary << "-#{configuration["architecture"]}" unless configuration["architecture"] == "x86_64"
          configuration_summary
        else
          configuration_summary = configuration_str
        end

        configuration_summary
      end

      def categorize_run_types(run_types, all_run_types)
        # Categorize runs so that if everything fails, we just say "all"
        # To do this, categorize all the runs by what OS they are from:
        os_categories = all_run_types.group_by { |type| type.split("-")[0] }
        run_categories = {}
        run_categories["all"] = all_run_types - [ "acceptance" ]
        run_categories["unix"] = os_categories.reject { |c,t| c == "windows" }.values.flatten
        run_categories["linux"] = os_categories.reject { |c,t| %w{aix solaris bsd windows}.include?(c) }.values.flatten
        run_categories["bsd"] = os_categories.select { |c,t| c =~ /bsd/ }.values.flatten
        run_categories.merge!(os_categories)
        run_categories.each do |category, types|
          next if types.empty?
          # If every type in the category is in run_types, replace those types with the category
          if (types - run_types).empty?
            run_types = run_types - types + [ category ]
          end
        end
        run_types.sort.uniq
      end

      #
      # Cache operations
      #
      def delete_cache
        report_cache.delete_cache(build.url, prefix: "stages")
      end

      def read_cache
        report_cache.read_cache(build.url, prefix: "stages")
      end

      def write_cache(value)
        report_cache.write_cache(build.url, value, prefix: "stages")
      end
    end
  end
end

require_relative "run_report"
