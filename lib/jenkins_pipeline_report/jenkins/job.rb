require "set"
require_relative "build"

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

      #
      # The list of fields that will be retrieved in Job.data.
      #
      # @return [String] The list of fields that will be in Job.data.
      #
      JOB_BUILD_FIELDS = %w{
        number
        timestamp
        actions[causes[upstreamUrl,upstreamBuild]]
        target[url]
      }.join(",").freeze
      JOB_FIELDS = %W{
        name url nextBuildNumber
        upstreamProjects[name] downstreamProjects[name]
        activeConfigurations[url]
        actions[processes[url]]
        property[parameterDefinitions[*[*]]]
        allBuilds[#{JOB_BUILD_FIELDS}]
      }.join(",").freeze

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
          @data || load || refresh
        end
      end

      #
      # Load the job data from cache
      #
      def load
        @data = cache.read_cache(url)
        builds.each { |build| build.add_to_upstreams } if @data
        @data
      end

      #
      # Load or reload the job data from Jenkins
      #
      def refresh
        new_data = cache.get(url, "tree=#{JOB_FIELDS}")
        if @data && new_data["nextBuildNumber"] < @data["nextBuildNumber"]
          raise "Job #{url} has been deleted and recreated! nextBuildNumber was #{old_value["nextBuildNumber"]}, is now #{new_value["nextBuildNumber"]}"
        end
        @data = new_data
        builds.each { |build| build.add_to_upstreams }
        cache.write_cache(url, @data)
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
    end
  end
end
