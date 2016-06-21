require "jenkins_api_client"
require_relative "job"

module JenkinsPipelineReport
  module Jenkins
    # We cache information about the list of jobs, but nothing else. NOTE:these
    # are only top-level jobs, not process or matrix jobs. Those are cached
    # when you read the jobs themselves.
    class Server
      #
      # Create a new Server.
      #
      # @param cache [Cache] The cache for all server objects.
      # @param url [String] The URL to this server.
      # @param client_options [Hash] Options to JenkinsApi::Client.
      #
      def initialize(cache, url, **client_options)
        @cache = cache
        @url = url
        @client_options = client_options
        @client = JenkinsApi::Client.new(server_url: url, **client_options)
        @jobs = {}
      end

      #
      # The cache object this Server is cached in.
      #
      # @return [Cache] The cache object this Server is cached in.
      #
      attr_reader :cache

      #
      # The server URL.
      #
      # @return [String] The server URL.
      #
      attr_reader :url

      #
      # The options used for the JenkinsApi::Client.
      #
      # @return [Hash] The options used for the JenkinsApi::Client.
      #
      attr_reader :client_options

      #
      # Get top-level jobs on the server (no processes or active configurations).
      #
      # @return [Hash<String, Job>] A list of all jobs on the server, from their
      #   path (`/job/my-job/`) to the Job object.
      #
      def jobs
        data["jobs"].map { |data| cache.job(data["url"]) }
      end

      #
      # Get a particular job.
      #
      # @param [String] path The path to the job on the server. Can be absolute
      #   (`/job/my-job/`), or relative to `/job` (`my-job`).
      #
      # @return [Job] The Job in question. If the Job does not exist on the
      #   server, asking it for information will throw an exception.
      #
      def job(path)
        path = File.expand_path(path, "/job")
        path = "#{path}/" unless path.end_with?("/")
        raise "OMG #{path}" if path.start_with?("/job/job")
        @jobs[path] ||= Job.new(self, path)
      end

      # @api private
      def job_data(url)
        # Grab the build data for a particular build from allBuilds. Used to make
        # certain immutable build data quick to load and to link up processes and
        # downstreams without having to load all the builds.
        data["jobs"].find { |data| data["url"] == url }
      end

      SERVER_FIELDS = "jobs[url,upstreamJobs[url],downstreamJobs[url]]".freeze

      #
      # Get data about the server.
      #
      # @return [Hash] Build data from the server.
      #
      def data
        @data || load || refresh
      end

      #
      # Load the Jenkins server data from cache
      #
      def load
        @data = cache.read_cache(url)
      end

      #
      # Load or reload the Jenkins server data from Jenkins
      #
      def refresh
        @data = get("", "tree=#{SERVER_FIELDS}")
        cache.write_cache(url, @data)
        @data
      end

      #
      # Get a particular build.
      #
      # @param path [String] The full path to the given build, including its
      #    job. Can be absolute (`/job/my-job/1/`) or relative to `/job`
      #    (`my-job/1/`).
      #
      # @return [Build] The Build in question. If the Build or Job does not exist
      #    on the server, asking it for information will throw an exception.
      #
      def build(build_path)
        job_path = File.dirname(path)
        build_number = File.basename(path).to_i
        job(job_path).build(build_number)
      end

      #
      # Get data from the cache or Jenkins server.
      #
      # @param path [String] The path to the object (excluding `/api/json`).
      #   e.g. `/job/my-job`. Always relative to url.
      # @param args [Array] Arguments to pass verbatim to client.
      # @return [Hash,Array] The parsed response.
      #
      def get(path, query=nil, json: true)
        Cli.logger.info "GET #{File.join(url, path)}"
        Cli.logger.debug "Query: #{query}" if query
        path = File.join(URI(url).path, path)
        if json
          client.api_get_request(path, query)
        else
          client.api_get_request(path, query, nil, true).body
        end
      end

      private

      attr_reader :client
    end
  end
end
