require_relative "stage_report"

module JenkinsPipelineReport
  module Report
    class RunReport < StageReport
      attr_reader :parent_report

      def initialize(parent_report, build)
        super(parent_report.build_report, build)
        @parent_report = parent_report
      end

      def build_report
        parent_report.build_report
      end

      def stage_path
        # Get rid of "job" from the top of the path. Generally the result will
        # just be `name`, but sometimes it'll be a multipath, so it pays to be
        # correct.
        path = Pathname(build.job.path).relative_path_from(Pathname(parent_report.build.job.path)).to_s
        configuration_summary(path)
      end

      def generate_queue_delay
        queue_delay = retries.first.timestamp - parent_report.build.timestamp
        queue_delay unless queue_delay < 10
      end

      #
      # Get the existing report, if there is one.
      #
      def report?
        report = parent_report.report?
        run_report = report && report["runs"] && report["runs"][stage_path]
        return nil if run_report && run_report["url"] != build.url
        run_report
      end
    end
  end
end
