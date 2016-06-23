require_relative "stage_report"

module JenkinsPipelineReport
  module Report
    class RunReport < StageReport
      attr_reader :stage_report

      def initialize(stage_report, retries)
        super(stage_report.build_report, retries)
        @stage_report = stage_report
      end

      def stage_path
        # Get rid of "job" from the top of the path. Generally the result will
        # just be `name`, but sometimes it'll be a multipath, so it pays to be
        # correct.
        Pathname(build.job.path).relative_path_from(Pathname(stage_report.build.job.path)).to_s
      end

      def generate_queue_delay
        retries.first.timestamp - stage_report.build.timestamp
      end
    end
  end
end
