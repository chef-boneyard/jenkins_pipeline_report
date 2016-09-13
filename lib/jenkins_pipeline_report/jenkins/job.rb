require "set"
require_relative "jenkins_object"
require_relative "build"
require_relative "../exceptions"

module JenkinsPipelineReport
  module Jenkins
    class Job < JenkinsObject
      # @api private
      # @see Server#job
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

      LAST_BUILD_FIELDS = %w{
        lastBuild lastCompletedBuild lastSuccessfulBuild lastFailedBuild lastUnsuccessfulBuild
        lastStableBuild lastUnstableBuild
      }
      LAST_BUILD_FIELDS.each do |field|
        method_name = field.gsub(/([A-Z][a-z]+)/) { |word| "_#{word.downcase}" }
        class_eval <<-EOM, __FILE__, __LINE__+1
          def #{method_name}
            build = data(#{field.inspect})
            self.build(build["number"].to_i) if build
          end
        EOM
      end

      #
      # Get the parent job if this is not directly under the root.
      #
      # @return [Job,nil] The parent job, or nil if there is no parent.
      #
      def parent
        path = Pathname(self.path)
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
        static_data("property").each do |property|
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
        static_data("upstreamProjects").map do |job|
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
        static_data("downstreamProjects").map do |job|
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
        if static_data("activeConfigurations")
          static_data("activeConfigurations").map do |job|
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
        static_data("actions").each do |action|
          next unless action["processes"]
          action["processes"].each do |job|
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

      # Static job fields
      STATIC_FIELDS = %w{
        name url upstreamProjects[name] downstreamProjects[name]
        activeConfigurations[url]
        property[parameterDefinitions[*[*]]]
        scm[userRemoteConfigs[url]]
        actions[processes[url]]
      }
      FIELDS = STATIC_FIELDS +
        LAST_BUILD_FIELDS.map { |field| "#{field}[number]" } +
        %W{
          allBuilds[#{Build::STATIC_FIELDS.join(",")}]
        }

      private

      def fetch_data
        # First we load old data, so we can check for job recreation.
        old_data = @data || load_data
        old_build = old_data["allBuilds"].first if old_data

        super do |fetched|
          if old_build
            fetched_build = fetched["allBuilds"].find { |build| build["number"] == old_build["number"] }
            unless fetched_build && old_build["timestamp"] == fetched_build["timestamp"]
              raise JobRecreatedError, "Job #{url} has been deleted and recreated! First build used to be #{old_build}, is now #{fetched_build}!"
            end
          end
        end
      end

      # Called after fetch_data and load
      def updated_data(data)
        data["allBuilds"].each do |build_data|
          build = build(build_data["number"])
          build.static_data = build_data
        end
      end
    end
  end
end
