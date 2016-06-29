require "uri"
require "jenkins_api_client"
require "json"
require "fileutils"
require_relative "../cli"
require_relative "server"

module JenkinsPipelineReport
  #
  # Jenkins objects from multiple servers, cached in memory and disk.
  #
  module Jenkins
    class Cache
      #
      # Client options that will be used for all server connections.
      #
      # @return [Hash] Hash of client options to `JenkinsAPI::Client`, including
      #   `identity_file`, a link to a private key used on the Jenkins server.
      #
      attr_reader :client_options

      #
      # The logger to log to.
      #
      # @return [Logger] The logger to log to.
      #
      attr_reader :logger

      #
      # The directory where jenkins data will be cached.
      #
      attr_reader :cache_directory

      #
      # Function that will be called to determine if an object should be cached.
      #
      attr_reader :should_cache

      #
      # Create a new Jenkins multi-server cache.
      #
      # @param cache_directory [String] Path to a cache directory under which Jenkins
      #   data is cached, to get
      # @param client_options [Hash] Hash of client options to `JenkinsAPI::Client`, including
      #   `identity_file`, a link to a private key used on the Jenkins server.
      #
      def initialize(cache_directory: nil, logger: Cli.logger, should_cache: default_should_cache, client_options: {})
        @cache_directory = cache_directory
        @logger = logger
        @client_options = client_options
        @should_cache = should_cache
        @servers = {}
        @cache_version = nil
        load_servers
      end

      #
      # Get a list of servers that have been cached or referenced.
      #
      # @return [Hash<String,Server>] A list of the servers being referenced or
      #   cached.
      #
      attr_reader :servers

      #
      # Get the Jenkins object at the given URL.
      #
      # @return [Server, Job, Build] The Jenkins object at the given URL.
      #
      def jenkins_object(url)
        path = URI(url).path
        if path == "" || path == "/"
          server(url)
        elsif File.basename(path) =~ /^\d+$/
          build(url)
        else
          job(url)
        end
      end

      #
      # Get the server
      #
      # @param url URL to the server. Any path on the end of the URL will be removed,
      #   e.g. `http://my.jenkins.com/job/my-job` will be stripped down to
      #   `http://my.jenkins.com`.
      #
      # @return [Server] The Server in question.
      #
      def server(url)
        url = URI(url)
        url.path = ""
        servers[url.to_s] ||= Server.new(self, url.to_s, client_options)
      end

      #
      # Get a particular job by URL.
      #
      # @param url [String] The job URL, e.g. `http://my.jenkins.com/job/my-job/`.
      #
      # @return [Job] The Job in question. If the Job does not exist on the
      #   server, asking it for information will throw an exception.
      #
      def job(url)
        server(url).job(URI(url).path)
      end

      #
      # Get a particular build.
      #
      # @param url [String] The build URL, e.g. `http://my.jenkins.com/job/my-job/1/`.
      #
      # @return [Build] The Build in question. If the Build or Job does not exist
      #    on the server, asking it for information will throw an exception.
      #
      def build(url)
        job_url = "#{File.dirname(url)}/"
        build_number = File.basename(url).to_i
        job(job_url).build(build_number)
      end

      #
      # Get all builds on all known servers.
      #
      def builds
        servers.flat_map { |server| server.builds }
      end

      #
      # Cache methods
      #

      #
      # Token indicating whether data is valid. Objects store this token when
      # they fetch from Jenkins. It is checked on access: if the token has
      # changed since they last loaded from Jenkins, they force a refresh.
      #
      attr_reader :cache_version

      #
      # Invalidate the entire cache. This causes all objects in the cache to be
      # invalidated; the first access to a Jenkins object after this point will
      # always fetch.
      #
      def invalidate
        @cache_version ||= 0
        @cache_version += 1
      end

      def invalidated?(jenkins_object)
        jenkins_object.cache_version != cache_version
      end

      def should_cache?(jenkins_object)
        should_cache.call(jenkins_object)
      end

      #
      # The cache filename for a given URL.
      #
      # @param url [String] The URL to the data (e.g. `http://my.jenkins.com/job/my-job/1/`)
      # @param json [Boolean] Whether the data is JSON or raw (like consoleText). Defaults to `true`.
      # @return [String] The absolute filename of the data on disk.
      #
      # @api private
      def cache_filename(url, json)
        uri = URI(url)
        filename = File.join(uri.host, uri.path)
        filename.sub!(/\/+$/, "") # remove trailing slashes
        filename = "#{filename}.json" if json
        filename.gsub!(/[^\w\.-_\/\\]/, "-")
        # strip bad filename characters
        File.join(cache_directory, filename)
      end

      #
      # Read Jenkins data from the cache.
      #
      # @param url [String] The URL to the data (e.g. `http://my.jenkins.com/job/my-job/1/`)
      # @param json [Boolean] Whether the data is JSON or raw (like consoleText). Defaults to `true`.
      # @return [Hash,String] The decoded JSON or raw data at the URL, or `nil` if none was found.
      #
      # @api private
      def read_cache(url, json: true)
        filename = cache_filename(url, json)
        if File.exist?(filename)
          logger.debug("Reading cache #{filename}")
          if json
            JSON.parse(IO.read(filename))
          else
            IO.read(filename)
          end
        end
      end

      #
      # Write Jenkins data to the cache.
      #
      # @param url [String] The URL to the data (e.g. `http://my.jenkins.com/job/my-job/1/`)
      # @param data [Hash,String] The data to write (JSON hash or raw data).
      # @param json [Boolean] Whether the data is JSON or raw (like consoleText). Defaults to `true`.
      #
      # @api private
      def delete_cache(url, json: true)
        filename = cache_filename(url, json)
        if File.exist?(filename)
          logger.debug("Deleting cache #{filename}")
          File.delete(filename)
        end
      end

      #
      # Write Jenkins data to the cache.
      #
      # @param url [String] The URL to the data (e.g. `http://my.jenkins.com/job/my-job/1/`)
      # @param data [Hash,String] The data to write (JSON hash or raw data).
      # @param json [Boolean] Whether the data is JSON or raw (like consoleText). Defaults to `true`.
      #
      # @api private
      def write_cache(url, data, json: true)
        filename = cache_filename(url, json)
        logger.debug("Writing cache #{filename}")
        FileUtils.mkdir_p(File.dirname(filename))
        if json
          IO.write(filename, JSON.dump(data))
        else
          IO.binwrite(filename, data)
        end
      end

      # By default, cache only servers and jobs
      def default_should_cache
        proc do |jenkins_object|
          case jenkins_object
          when Server, Job
            true
          else
            false
          end
        end
      end

      private

      # Load in the list of servers from cache
      def load_servers
        if File.directory?(cache_directory)
          Dir.entries(cache_directory) do |server_json|
            next if server_json.directory?
            next unless server_json.end_with?(".json")
            url = JSON.parse(IO.read(server_json))["url"]
            server(url)
          end
        end
      end

    end
  end
end
