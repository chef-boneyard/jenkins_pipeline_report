require "set"
require_relative "build"
require_relative "../exceptions"

module JenkinsPipelineReport
  module Jenkins
    class Job
      def initialize(server, path)
        @server = server
        @path = path
        @builds = {}
      end

      #
      # The Server containing this job.
      #
      # @return [Server] The Server containing this job.
      #
      attr_reader :server

      #
      # The path to this job (e.g. `/job/my-job/`).
      #
      # @return [String] The path to this job (e.g. `/job/my-job/`).
      #
      attr_reader :path

      #
      # The URL to this job (e.g. `http://my.jenkins.com/job/my-job/`).
      #
      # @return [String] The URL to this job (e.g. `http://my.jenkins.com/job/my-job/`).
      #
      def url
        File.join(server.url, path)
      end

      #
      # The name of this job (e.g. `http://my.jenkins.com/job/my-job/` -> `my-job`).
      #
      # This is always the last path component, even if the job has multiple
      # components, so matrix build jobs like
      # `http://my.jenkins.com/job/my-job/a=b,c=d` will have possibly non-unique
      # names like `a=b,c=d`. Use `path` if you need a unique identifier for a
      # job.
      #
      # @return [String] The name of this job (e.g. `http://my.jenkins.com/job/my-job/` -> `my-job`).
      #
      def name
        File.basename(url)
      end

      #
      # Get all builds for this job.
      #
      # Will be lazily fetched if we don't have the list yet. All Builds will
      # have their data filled in.
      #
      # @return [Array<Build>] All builds for this job.
      #
      def builds
        data("allBuilds").map { |data| build(data["number"].to_i) }
      end

      #
      # Get a particular build by its number.
      #
      # @param number [Integer,String] The job number, e.g. 1.
      #
      # @return [Job] The Build in question. If the Build does not exist on the
      #   server, asking it for information will throw an exception.
      #
      def build(number)
        @builds[number.to_i] ||= Build.new(self, number)
      end

      #
      # Get the next build number for this job.
      #
      # @return [Integer] The next build number for this job.
      #
      def next_build_number
        data("nextBuildNumber")
      end

      #
      # Get the parent job if this is not directly under the root.
      #
      # @return [Job,nil] The parent job, or nil if there is no parent.
      #
      def parent
        path = Pathname(path)
        while true
          parent = path.dirname
          return if parent == path
          if parent == "/job"
            return server.job(path.to_s)
          end
          path = parent
        end
      end

      #
      # Get the type of job.
      #
      # @return [Symbol] The type of Job:
      #   - `:run` if this is a matrix job of its `parent`.
      #   - `:process` if this is a process job from a `parent`.
      #   - `:top_level` if this is a top level job.
      #
      def type
        @type ||= begin
          if parent
            if parent.active_configurations.include?(self)
              :run
            elsif parent.processes.include?(self)
              :process
            else
              raise "Unknown job type for #{url}! Doesn't seem to be a matrix or process job of #{parent.url} ..."
            end
          else
            :top_level
          end
        end
      end

      #
      # Parameters for this job.
      #
      # @return [Hash<String>] Parameters for this job, each of which has
      #   :name, :description, :type and :default.
      #
      def parameters
        parameters = {}
        data("property").each do |property|
          next unless property["parameterDefinitions"]
          property["parameterDefinitions"].each do |parameter|
            parameters[parameter["name"]] = {
              name: parameter["name"],
              description: parameter["description"],
              type: parameter["type"],
              default: parameter["default"]
            }
          end
        end
      end

      #
      # Upstreams for this job.
      #
      # @return [Array<Job>] Upstreams for this job.
      def upstreams
        data("upstreamProjects").map do |job|
          job_url = "#{File.join(File.dirname(url), job["name"])}/"
          cache.job(job_url)
        end
      end

      #
      # Downstreams for this job.
      #
      # @return [Array<Job>] Downstreams for this job.
      #
      def downstreams
        data("downstreamProjects").map do |job|
          job_url = "#{File.join(File.dirname(url), job["name"])}/"
          cache.job(job_url)
        end
      end

      #
      # Active configurations (matrix jobs) for this job.
      #
      # @return [Array<Job>] Active configurations (matrix builds) for this job.
      #
      def active_configurations
        if data("activeConfigurations")
          data("activeConfigurations").map do |job|
            cache.job(job["url"])
          end
        else
          []
        end
      end

      #
      # Processes (extra actions) for this job.
      #
      # @return [Array<Job>] Processes for this job.
      #
      def processes
        processes = []
        data("actions").each do |action|
          next unless data("processes")
          data("processes").each do |job|
            processes << cache.job(job["url"])
          end
        end
        processes.uniq
      end

      #
      # Find all the triggers (upstream-most) for this job.
      #
      # @return [Array<Job>] The triggers that can cause this job.
      #
      def triggers
        if upstreams.empty?
          [ self ]
        else
          upstreams.flat_map { |upstream| upstream.triggers }.uniq.sort_by { |job| job.name }
        end
      end

      #
      # Find all the terminal (downstream-most) jobs this job can reach.
      #
      # @return [Array<Job>] The downstream-most jobs this job can reach.
      #
      def terminals
        if downstreams.empty?
          [ self ]
        else
          downstreams.flat_map { |downstream| downstream.terminals }.sort_by { |job| job.name }
        end
      end

      #
      # Get all the downstreams, ordered by upstreams first.
      #
      # @return [Array<Job>] All downstreams from this job, ordered by upstreams first.
      #
      def all_downstreams
        result = [ self ]
        downstreams.each { |downstream| result |= downstream.all_downstreams }
        result
      end

      JOB_BUILD_FIELDS = %w{
        number
        timestamp
        actions[causes[upstreamUrl,upstreamBuild]]
        target[url]
      }.join(",").freeze

      #
      # The list of fields that will be retrieved in Job.data.
      #
      # @return [String] The list of fields that will be in Job.data.
      #
      JOB_FIELDS = %W{
        name url nextBuildNumber
        upstreamProjects[name] downstreamProjects[name]
        activeConfigurations[url]
        actions[processes[url]]
        property[parameterDefinitions[*[*]]]
        allBuilds[#{JOB_BUILD_FIELDS}]
      }.join(",").freeze

      #
      # Whether to cache jobs on disk.
      #
      CACHE_JOBS = true

      #
      # The job JSON data.
      #
      # Will be lazily fetched if we don't have it yet.
      #
      # Will contain only the fields listed in the #JOB_FIELDS constant.
      #
      # @return [Hash<String,*>] The job JSON data.
      #
      # @see JOB_FIELDS The list of fields in `data`
      #
      def data(field=nil)
        if field
          if @data
            @data[field] || server.job_data(url)[field]
          else
            # Use data from the job list, if the field is there, rather than
            # loading data for this particular job.
            server.job_data(url)[field] || data[field]
          end
        else
          @data || load || refresh(recursive: false)
        end
      end

      #
      # Load the job data from cache
      #
      def load
        if CACHE_JOBS
          @data = cache.read_cache(url)
          builds.each { |build| build.add_to_upstreams } if @data
        end
        @data
      end

      #
      # Load or reload the job data from Jenkins.
      #
      # @param recursive [Boolean] `true` to refresh each build, `false` to just
      #   refresh the job and its *list* of builds. as well as any matrix jobs
      #   and processes. Downstreams and upstreams will not be refreshed.
      #   Defaults to `false`.
      # @param pipeline [Boolean] Whether to refresh all jobs in the pipelines.
      #   Defaults to `false`.
      #
      def refresh(recursive: true, pipeline: false, invalidate: false)
        if invalidate && !CACHE_JOBS
          @data = nil
        else
          fetch
        end
        if recursive
          # Since we're refreshing active configurations directly after, we don't
          # bother with recursive refresh of builds. More efficient to grab the
          # whole job at once.
          builds.each { |build| build.refresh(recursive: false, pipeline: false, invalidate: invalidate) }
        end
        if pipeline
          all_downstreams.each { |job| job.refresh(recursive: false, pipeline: false, invalidate: invalidate) }
          # active_configurations.each { |job| job.refresh }
          # processes.each { |job| job.refresh }
        end
        @data
      end

      # @api private
      def build_data(number)
        # Grab the build data for a particular build from allBuilds. Used to make
        # certain immutable build data quick to load and to link up processes and
        # downstreams without having to load all the builds.
        data("allBuilds").find { |data| data["number"].to_i == number }
      end

      private

      def cache
        server.cache
      end

      def fetch
        # First we load, so we can check for job recreation.
        load

        # Fetch the new job data.
        fetched = cache.fetch(url, "tree=#{JOB_FIELDS}")

        # Verify the queue hasn't jumped by looking at a build
        if @data
          old_build = @data["allBuilds"].first
          fetched_build = fetched["allBuilds"].find { |build| build["number"] == old_build["number"] }
          if old_build && old_build["timestamp"] != fetched_build["timestamp"]
            raise JobRecreatedError, "Job #{url} has been deleted and recreated! First build used to be #{old_build}, is now #{fetched_build}!"
          end
        end

        # Set data to fetched data
        @data = fetched

        # Write to cache if needed
        if CACHE_JOBS
          cache.write_cache(url, @data)
        end

        # Link build's upstreams and target
        builds.each { |build| build.add_to_upstreams }
      end
    end
  end
end
