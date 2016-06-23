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
      # Get top-level jobs on the server (no processes or matrix build jobs).
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

      #
      # Get all top-level builds on the server.
      #
      # @return [Array<Build>] All Builds from all Jobs on the server. Does not
      #  include processes or matrix builds (only top level Jobs).
      #
      def builds
        jobs.flat_map { |job| job.builds }
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
      # The list of fields to get for the server.
      #
      SERVER_FIELDS = "url,jobs[url,upstreamJobs[url],downstreamJobs[url]]".freeze

      #
      # Whether to cache servers on disk.
      #
      CACHE_SERVERS = true

      #
      # Get data about the server.
      #
      # @return [Hash] Build data from the server.
      #
      def data
        @data || load || refresh(recursive: false)
      end

      #
      # Load the Jenkins server data from cache
      #
      def load
        if CACHE_SERVERS
          @data = cache.read_cache(url)
        end
      end

      #
      # Load (or reload) the Jenkins server data from Jenkins
      #
      # @param recursive [Boolean] Whether to refresh each job or just the list
      #   of jobs. :cache only caches things that can hit the disk cache.
      #   Defaults to `false`.
      # @param pipeline [Boolean] Whether to refresh all jobs in all pipelines
      #   (equivalent to recursive for server). Defaults to `false`.
      #
      def refresh(recursive: true, pipeline: false, invalidate: false)
        if invalidate && !CACHE_SERVERS
          @data = nil
        else
          fetch_data
        end
        if recursive || pipeline
          jobs.each { |job| job.refresh(recursive: recursive, pipeline: false, invalidate: invalidate) }
        end
        @data
      end

      #
      # Get data from the cache or Jenkins server.
      #
      # @param path [String] The path to the object (excluding `/api/json`).
      #   e.g. `/job/my-job`. Always relative to url.
      # @param args [Array] Arguments to pass verbatim to client.
      # @return [Hash,Array] The parsed response.
      #
      def fetch(path, query=nil, json: true)
        Cli.logger.info "GET #{File.join(url, path)}"
        Cli.logger.debug "Query: #{query}" if query
        path = File.join(URI(url).path, path)
        if json
          client.api_get_request(path, query)
        else
          client.api_get_request(path, query, nil, true).body
        end
      end

      #
      # Grab the job data for a particular job from the server. Used to make
      # certain immutable build data like upstreams and downstreams
      # quick to load without having to fetch or read in the actual job
      # information.
      #
      # @return [Hash] The partial job data, or `nil` if the job has not been
      #   loaded yet or if the build is not in the job's list.
      #
      # @api private
      # @see JOB_BUILD_FIELDS
      #
      def job_data(url)
        return nil unless @data || load
        data["jobs"].find { |data| data["url"] == url }
      end

      private

      def fetch_data
        @data = fetch("", "tree=#{SERVER_FIELDS}")
        # It doesn't technically store the URL, but we need to remember it.
        @data["url"] ||= url
        if CACHE_SERVERS
          cache.write_cache(url, @data)
        end
      end

      attr_reader :client
    end
  end
end
