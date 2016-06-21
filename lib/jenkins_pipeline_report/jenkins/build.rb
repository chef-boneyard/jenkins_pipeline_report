module JenkinsPipelineReport
  module Jenkins
    class Build
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
        timestamp_to_datetime(data("timestamp"))
      end

      #
      # The duration of this build.
      #
      # @return [Numeric] The duration of this build, in seconds.
      #
      def duration
        duration_to_seconds(data("duration").to_f)
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
        if data("runs")
          data("runs").map { |data| cache.build(data["url"]) }
        else
          []
        end
      end

      #
      # Retries of this build (builds with the same job), oldest first.
      #
      # @return [Array<Build>] The retries for this build.
      #
      def retries
        results = [ self ]
        downstreams.each do |downstream|
          results |= downstream.retries if downstream.job == job
        end
        results
      end

      #
      # The "stages" of this build: the latest retry of each build job, along
      # with their successors (downstreams).
      #
      # @return [Array<Build>] The stages this build has gone through, with
      #   retries deduped (one build per job).
      #
      def stages
        stages = [ retries.last ]
        next_stages = {}
        downstreams.each do |downstream|
          next_stages[job] = downstream
        end
        next_stages.each do |job, downstream|
          stages |= downstream.stages
        end
        stages
      end

      #
      # Get the triggers for this build (ultimate upstreams).
      #
      def triggers
        @triggers ||= begin
          result = upstreams.flat_map { |upstream| upstream.triggers }.uniq
          if result.empty?
            [ self ]
          end
        end
      end

      #
      # Get the upstream build of this build.
      #
      # @return [Build] The build that kicked this build off.
      # @see #downstreams
      #
      def upstreams
        @upstreams ||= begin
          actions = @data ? @data["actions"] : job.build_data(number)["actions"]
          upstreams = []
          actions.each do |action|
            next unless action["causes"]
            action["causes"].each do |cause|
              if cause["upstreamUrl"]
                # upstreamUrl is a path, e.g. /job/my-job/
                upstream_job = server.job(File.expand_path(cause["upstreamUrl"], "/"))
                # upstreamBuild is a build number, e.g. 1
                upstreams << upstream_job.build(cause["upstreamBuild"])
              end
            end
          end
          upstreams
        end
      end

      #
      # Get the target of this build process.
      #
      # @return [Build] The build this process targets.
      # @see #processes
      #
      def target
        @target ||= begin
          target = build_data("target")
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

      #
      # Get the console text for this build.
      #
      # This value is only cached if the build is complete; otherwise, it is
      # retrieved every time. It is not cached in memory, only on disk.
      #
      # @return [String] The console text for this build.
      #
      def console_text
        console_text_path = File.join(path, "consoleText")
        if in_progress?
          server.get(path, json: false)
        else
          server.cache_get(path, nil, json: false)
        end
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

      #
      # Get an artifact of this build as binary data.
      #
      # These are cached (on disk, not in memory).
      #
      # @return [String] The binary blob representing this artifact.
      #
      def artifact(relativePath)
        console_text_path = File.join(path, "artifacts", relativePath)
        server.cache_get(path, nil, json: false)
      end

      def refresh
        load_data(force: true)
      end

      #
      # The list of fields that will be retrieved in Job.data.
      #
      # @return [String] The list of fields that will be in Job.data.
      #
      BUILD_FIELDS = %W{
        number url result timestamp duration builtOn
        actions[causes[upstreamUrl,upstreamBuild],parameters[name,value]]
        artifacts[relativePath] failCount skipCount totalCount
        runs[url]
      }.join(",").freeze

      #
      # The build JSON data.
      #
      # Will be lazily fetched if we don't have it yet.
      #
      # Will contain only the fields listed in the #BUILD_FIELDS constant.
      #
      # @return [Hash<String,*>] The build JSON data.
      #
      # @see BUILD_FIELDS The list of fields in `data`
      #
      def data(field=nil)
        if field
          if @data
            @data[field]
          else
            # Prefer to check the build data, if we have the field there.
            job.build_data(number)[field] || data[field]
          end
        else
          @data || load || refresh
        end
      end

      # @api private
      def build_data(field)
        if @data
          @data[field]
        else
          job.build_data(number)[field]
        end
      end

      #
      # Load the job data from cache
      #
      def load
        @data = cache.read_cache(url)
        add_to_upstreams if @data
      end

      #
      # Load or reload the job data from Jenkins
      #
      def refresh
        new_data = cache.get(url, "tree=#{BUILD_FIELDS}")
        timestamp = @data && @data["timestamp"]
        timestamp ||= job.build_data(number)["timestamp"]
        if timestamp && timestamp != new_data["timestamp"]
          raise "Build #{url} has changed timestamps! Old: #{timestamp}, new: #{new_data[timestamp]}. Perhaps the queue was deleted and recreated?"
        end
        @data = new_data
        add_to_upstreams
        cache.write_cache(url, @data)
        @data
      end

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

      # @api private
      def add_to_upstreams
        upstreams.each do |upstream|
          upstream.add_downstream(self)
        end

        target.add_process(self) if target
      end

      private

      def cache
        job.server.cache
      end

      def server
        job.server
      end

      # 1462900986044 is "time since 1970 in milliseconds"
      def timestamp_to_datetime(timestamp)
        Time.at(timestamp.to_f / 1000.0).utc.to_s
      end

      # 13759911 is duration in milliseconds
      def duration_to_time(duration)
        duration.to_f / 1000.0
      end
    end
  end
end
