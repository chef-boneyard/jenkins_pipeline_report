require_relative "jenkins_object"

module JenkinsPipelineReport
  module Jenkins
    class Build < JenkinsObject
      #
      # Create a Build cache object.
      #
      # @param job [Job] The Job this build is cached in.
      # @param number [Integer] The build number.
      #
      def initialize(job, number)
        @job = job
        @number = number
        @runs = []
        @downstreams = []
        @processes = []
      end

      #
      # The job this build is cached in.
      #
      # @return [Job] The Job this build is cached in.
      #
      attr_reader :job

      #
      # The build number of this build.
      #
      # @return [Integer] The build number of this build.
      #
      attr_reader :number

      #
      # The URL to this build (e.g. `http://my.jenkins.com/job/my-job/1/`).
      #
      # @return [String] The URL to this build (e.g. `http://my.jenkins.com/job/my-job/1/`).
      #
      def url
        "#{File.join(job.url, number.to_s)}/"
      end

      #
      # The path to this build (e.g. `/job/my-job/1/`).
      #
      # @return [String] The path to this build (e.g. `/job/my-url/1/`).
      #
      def path
        "#{File.join(job.path, number.to_s)}/"
      end

      #
      # The result of the build (e.g. "FAILURE", "ABORTED", "SUCCESS")
      #
      # @return [String] The result of the build.
      #
      def result
        data("result")
      end

      #
      # The timestamp of this build.
      #
      # @return [DateTime] The timestamp of this build.
      #
      def timestamp
        timestamp_to_datetime(static_data("timestamp"))
      end

      #
      # The duration of this build.
      #
      # @return [Numeric] The duration of this build, in seconds.
      #
      def duration
        duration = data("duration")
        duration_to_seconds(duration.to_f) if duration
      end

      #
      # The end time of the build.
      #
      # @return [DateTime] The end time of this build (timestamp+duration), or `nil` if it has no duration.
      #
      def end_timestamp
        timestamp + duration if duration
      end

      #
      # Tell whether this build is failed (not in progress or succeeded).
      #
      # @return [Boolean] Whether this build is failed.
      #
      def failed?
        !succeeded? && !in_progress?
      end

      #
      # Tell whether this build succeeded (reuslt is "SUCCESS").
      #
      # @return [Boolean] Whether this build succeeded.
      #
      def succeeded?
        result == "SUCCESS"
      end

      #
      # Tell whether this build is in progress (result is nil).
      #
      # @return [Boolean] Whether this build is in progress.
      #
      def in_progress?
        result.nil?
      end

      #
      # Get all runs for this matrix build (if any).
      #
      # @return [Array<Build>] The runs for this build.
      #
      def runs
        runs = data("runs") || []
        runs.map { |run| cache.build(run["url"]) }.select { |run| run.upstreams.include?(self) }
      end

      #
      # Retries of this build (builds with the same job), oldest first.
      #
      # @return [Array<Build>] The retries for this build.
      #
      def retries(result=nil)
        if result
          # Find the predecessor(s) to this job and ask for our retries from there;
          # it's entirely possible all our retries are downstream of that.
          if result.add?(self)
            downstreams.each do |downstream|
              downstream.retries(result) if downstream.job == job
            end
          end

        else
          # This is the initial call to retries. Find our parents and look at
          # their downstreams to find retries.
          result = Set.new

          parents = self.parents
          if parents.any?
            # If we have parents, look for our retries there.
            parents.each do |parent|
              parent.downstreams.each do |downstream|
                downstream.retries(result) if downstream.job == job
              end
            end
          else
            # We have no parents; we are the only one who has our retries.
            retries(result)
          end
        end

        result.to_a.sort_by { |build| build.number }
      end

      #
      # The build(s) that triggered this set of retries.
      #
      # @return [Build] The parent builds of this build, or empty if none.
      #
      def parents(result=nil)
        if result
          if @parents
            result |= @parents
          else

            upstreams.each do |upstream|
              if upstream.job == job
                upstream.parents(result)
              else
                result.add(upstream)
              end
            end

            result.to_a
          end
        else
          @parents ||= parents(Set.new)
        end
      end

      #
      # Get the triggers for this build (ultimate upstreams).
      #
      # @return [Array<Build>] The triggers for this build.
      #
      def triggers
        @triggers ||= begin
          if upstreams.any?
            upstreams.flat_map { |upstream| upstream.triggers }.uniq
          else
            [ self ]
          end
        end
      end

      #
      # Get the user that triggered this build (if any).
      #
      # @return [User] The user that triggered this build (if any).
      #
      def triggered_by
        causes.each do |cause|
          if cause["userId"]
            return server.user(cause["userId"])
          end
        end
        nil
      end

      #
      # Get the upstream builds of this build.
      #
      # @return [Array<Build>] The build(s) that caused this build to start.
      # @see #downstreams
      #
      def upstreams
        @upstreams ||= begin
          upstreams = []
          causes.each do |cause|
            if cause["upstreamUrl"]
              # upstreamUrl is a path, e.g. /job/my-job/
              upstream_job = server.job(File.expand_path(cause["upstreamUrl"], "/"))
              # upstreamBuild is a build number, e.g. 1
              upstreams << upstream_job.build(cause["upstreamBuild"])
            end
          end
          upstreams
        end
      end

      #
      # Get the causes of this build.
      #
      # @return [Array<Hash<String,String>] An array of causes for the build.
      #
      def causes
        static_data("actions").flat_map { |action| action["causes"] || [] }
      end

      #
      # Get the target of this build process.
      #
      # @return [Build] The build this process targets.
      # @see #processes
      #
      def target
        @target ||= begin
          target = static_data("target")
          cache.build(target["url"]) if target && target["url"]
        end
      end

      #
      # Get all downstream builds (builds this build kicked off). This includes
      # matrix builds and retries.
      #
      # Only downstream builds that have been loaded will appear here. To be
      # certain you have all downstreams, grab all builds from downstream jobs.
      #
      # @return [Array<Build>] The builds this build kicked off.
      # @see #upstream
      # @see #add_downstream
      #
      attr_reader :downstreams

      #
      # Get processes (#job.processes that target this build).
      #
      # Only processes that have been loaded will appear here. To be sure you
      # have all processes,
      #
      # @return [Array<Build>] Processes targeting this build.
      # @see Job#processes
      # @see #add_process
      # @see #target
      #
      attr_reader :processes

      #
      # Get the parameters for this build.
      #
      # @param [Hash] The parameters for this build.
      #
      def parameters
        parameters = {}
        data["actions"].each do |action|
          next unless action["parameters"]
          action["parameters"].each do |parameter|
            parameters[parameter["name"]] = parameter["value"]
          end
        end
        parameters
      end

      CACHE_CONSOLE_TEXT = false

      #
      # Get the console text for this build.
      #
      # This value is not cached.
      #
      # @return [String] The console text for this build.
      #
      def console_text
        if CACHE_CONSOLE_TEXT
          url = File.join(self.url, "consoleText")
          console_text = cache.read_cache(url, json: false)
        end
        unless console_text
          path = File.join(self.path, "consoleText")
          console_text = server.api_get(path, json: false)
          if CACHE_CONSOLE_TEXT
            cache.write_cache(url, console_text, json: false)
          end
        end
        console_text
      end

      #
      # Get the list of artifacts for this build.
      #
      # @return [Array<String>] A list of relative paths to the artifacts.
      #   These may be passed to the `artifact()` method to actually
      #   retrieve the artifacts.
      #
      def artifacts
        data("artifacts").map { |artifact| artifact["relativePath"] }
      end

      CACHE_ARTIFACTS = false

      #
      # Get an artifact of this build as binary data.
      #
      # These are not cached.
      #
      # @return [String] The binary blob representing this artifact.
      #
      def artifact(relativePath)
        if CACHE_ARTIFACTS
          url = File.join(self.url, "artifacts", relativePath)
          artifact = cache.read_cache(url, json: false)
        end
        unless artifact
          path = File.join(self.path, "artifacts", relativePath)
          artifact = server.api_get(url, json: false)
          if CACHE_ARTIFACTS
            cache.write_cache(url, artifact, json: false)
          end
        end
        artifact
      end

      #
      # The list of fields that will be retrieved in Job.data.
      #
      # @return [String] The list of fields that will be in Job.data.
      #
      STATIC_FIELDS = %w{
        number url timestamp
        actions[causes[*],parameters[*]]
      }
      FIELDS = STATIC_FIELDS + %W{
        result duration builtOn
        failCount skipCount totalCount
        artifacts[relativePath]
        runs[url,#{STATIC_FIELDS.join(",")}]
      }

      #
      # Set another build as downstream of this one. (Internally used.)
      #
      # @api private
      #
      def add_downstream(build)
        # Figure out where to add the downstream to keep them sorted
        index = downstreams.index { |downstream| downstream.job == build.job && downstream.number >= build.number }
        if index
          downstreams.insert(index, build) unless downstreams[index] == build
        else
          downstreams << build
        end
      end

      #
      # Set another build as a process of this one. (Internally used.)
      #
      # @api private
      #
      def add_process(build)
        # Figure out where to add the process to keep them sorted
        index = processes.find { |process| process.job == build.job && process.number > build.number }
        if index
          processes.insert(index, build)
        else
          processes << build
        end
      end

      def static_data=(data)
        data = super
        add_to_upstreams if data
        data
      end

      private

      # @api private
      def updated_data(data)
        add_to_upstreams

        # Tell the runs about the wonderful data we grabbed for them.
        if data["runs"]
          data["runs"].each do |run|
            cache.build(run["url"]).static_data = run
          end
        end
      end

      def add_to_upstreams
        upstreams.each do |upstream|
          upstream.add_downstream(self)
        end

        target.add_process(self) if target
      end

      def server
        job.server
      end

      # 1462900986044 is "time since 1970 in milliseconds"
      def timestamp_to_datetime(timestamp)
        Time.at(timestamp.to_f / 1000.0).utc
      end

      # 13759911 is duration in milliseconds
      def duration_to_seconds(duration)
        duration.to_f / 1000.0
      end

      def fetch_data
        if @data || @static_data || load_data
          timestamp = static_data("timestamp")
        end
        super do |fetched|
          if timestamp && timestamp != fetched["timestamp"]
            raise "Build #{url} has changed timestamps! Old: #{timestamp}, new: #{fetched[timestamp]}. Perhaps the queue was deleted and recreated?"
          end
        end
      end
    end
  end
end
