module JenkinsPipelineReport
  module Jenkins
    class JobTracker
      def initialize(job, tracker_cache=nil)
        @job = job
        @listeners = listeners
        @tracker_cache = tracker_cache
        load
        @in_progress_builds =
      end

      attr_reader :new_build_listeners
      attr_reader :

      def on_new_build(&block)
        new_build_listeners
      end

      def on_build_change(&block)
      end

      def on_change(&block)

      end

      def check
        job.
      end
    end
  end
end
