require "uri"
require "pathname"
require "jenkins_api_client"
require_relative "jenkins_cli"

class JenkinsPipeline
  attr_reader :client
  attr_reader :server_url
  attr_reader :job

  def initialize(job_url: "http://manhattan.ci.chef.co/job/chef-trigger-release",
                 identity_file: "~/.ssh/id_rsa",
                 **client_options)
    uri = URI(job_url)
    @job = File.basename(uri.path)
    # Remove the path and query from the URL to get the server URL
    uri.path = ""
    uri.query = nil
    @server_url = uri.to_s

    @job = job
    @client = JenkinsApi::Client.new(server_url: server_url, identity_file: identity_file, **client_options)
  end

  #
  # The jobs involved in this pipeline.
  #
  def jobs
    unless @jobs
      @jobs = {}
      load_job(job)
      set_retries_and_downstreams
    end
    @jobs
  end

  #
  # Gets you pipeline builds. i.e.
  #
  # [
  #   {
  #     "chef-trigger-release" => { "number" => 101, "result" => "SUCCESS", ... },
  #     "chef-build" => { "number" => 432, "result" => "FAILURE", ... },
  #     ...
  #   }
  # ]
  #
  def builds
    jobs[job]["allBuilds"].sort_by { |build| build["number"] }
  end

  def build_stages(build)
    build_stages = []
    # Take upstreams of this build and build the first bit of pipeline
    while build
      build_stages.unshift(build)
      if build["upstreams"]
        if build["upstreams"].size > 1
          raise MultipleUpstreamsError, "Multiple upstreams for build #{build["url"]}: #{build["upstreams"].map { |b| "#{b["job"]} ##{b["number"]}" }.join(", ")}"
        end
        build = build["upstreams"].first
      else
        build = nil
      end
    end

    # Take downstreams of this build, and take the latest retry thereof
    build = build_stages.last
    while build
      if build["downstreams"]
        if build["downstreams"].size > 1
          raise MultipleDownstreamsError, "Multiple downstreams for build #{build["url"]}: #{build["downstreams"].map { |b| "#{b["job"]} ##{b["number"]}" }.join(", ")}"
        end
        build = build["downstreams"].first
      else
        build = nil
      end
      build_stages << build if build
    end

    build_stages
  end

  #
  # Get all runs for the given build.
  #
  def runs(build)
    path = URI(build["url"]).path
    job_name = File.basename(File.dirname(path))
    build_number = File.basename(path).to_i
    runs = fetch_runs(job_name, build_number)
    # Ridiculously, things get added into our matrix that aren't ours
    runs.select! { |run| parse_run_url(run["url"])[1] == build_number }
    runs.map! { |run| normalize_run(run) }
    runs.sort_by { |run| run["configuration"] }
  end

  #
  # Parse a run URL into job name, build number and configuration string.
  #
  # e.g. parse_run_url("http://manhatten.ci.chef.co/job/chef-test/342/architecture=x86_64,platform=acceptance,project=chef,role=tester")
  # -> chef-test, 243, acceptance
  #
  def parse_run_url(url)
    # Extract pertinent data from URL
    # /job/chef-test/342/architecture=x86_64,platform=acceptance,project=chef,role=tester
    path = URI(url).path
    job = File.basename(File.dirname(File.dirname(path)))
    build_number = File.basename(File.dirname(path))
    configuration_str = File.basename(path)

    # Check for alternate URL type:
    # /job/chef-test/architecture=x86_64,platform=acceptance,project=chef,role=tester/342
    unless build_number =~ /^\d+$/
      build_number, configuration_str = configuration_str, build_number
    end

    build_number = build_number.to_i

    #
    # Summarize the configuration for easy consumption
    #
    # configuration is a hash
    configuration = {}
    configuration_str.split(",").sort_by { |name, value| name }.each do |name_value|
      name, value = name_value.split("=", 2)
      configuration[name] = value
    end

    case configuration["role"]
    when "builder", "tester"
      configuration_summary = configuration["platform"]
      configuration_summary << "-#{configuration["architecture"]}" unless configuration["architecture"] == "x86_64"
      configuration_summary
    else
      configuration_summary = configuration_str
    end

    [ job, build_number, configuration_summary ]
  end

  class JenkinsPipelineError < StandardError; end
  class MultipleUpstreamsError < JenkinsPipelineError; end
  class MultipleDownstreamsError < JenkinsPipelineError; end
  class ParseError < JenkinsPipelineError; end

  private

  def retry_ancestors(build)
    if build && build["retryOf"]
      ancestors = build["retryOf"]
      build["retryOf"].each do |number|
        ancestors |= retry_ancestors(get_cached_build(build["job"], number))
      end
      ancestors
    else
      []
    end
  end

  def set_retries_and_downstreams
    jobs.each do |job_name, job|
      by_upstream = {}
      job["allBuilds"].sort_by { |b| b["number"] }.each do |build|
        next unless build["upstreams"]
        build["upstreams"].dup.each do |upstream|
          existing_build = by_upstream[upstream]
          if existing_build
            # A build with a lower number (existing_downstream) has the
            # same upstream as us. Set this build as a retryOf that other build.
            build["retryOf"] ||= []
            build["retryOf"] |= [ existing_build["number"] ]
            build["upstreams"].delete(upstream)
            build.delete("upstreams") if build["upstreams"].empty?
          end
          by_upstream[upstream] = build
        end
      end
    end

    #
    # Add retries and combine retryOf and upstreams with our ancestors
    #
    jobs.each do |job_name, job|
      job["allBuilds"].each do |build|
        #
        # Follow the retryOf chain: if this build is a retryOf B, and B is a
        # retryOf C, then this build is a retryOf C.
        #
        build["retryOf"] = retry_ancestors(build)

        #
        # Set upstreams on the build to include upstreams from all builds we
        # are a retry of
        #
        ancestry = build["retryOf"].map { |number| get_cached_build(build["job"], number) }.compact
        build["upstreams"] ||= []
        build["upstreams"] |= ancestry.flat_map { |ancestor| ancestor["upstreams"] || [] }

        #
        # Set retries on all builds we are a retryOf to include this build
        #
        build["retryOf"].each do |number|
          upstream = get_cached_build(build["job"], number)
          if upstream
            upstream["retries"] ||= []
            upstream["retries"] |= [ build ]
          end
        end

        # Remove empty stuff for less clutter
        build.delete("retryOf") if build["retryOf"].empty?
        build.delete("upstreams") if build["upstreams"].empty?
      end
    end

    #
    # Set downstreams
    #
    jobs.each do |job_name, job|
      job["allBuilds"].each do |build|
        # If there are retries of this build, we'll set the downstreams from the final
        # retry.
        if build["upstreams"] && !build["retries"]
          #
          # Set downstreams on all upstream builds to include this build
          #
          build["upstreams"].each do |upstream|
            upstream = get_cached_build(upstream["job"], upstream["number"])
            if upstream
              upstream["downstreams"] ||= []
              upstream["downstreams"] |= [ build ]
            end
          end
        end
      end
    end
  end

  def fetch_job_and_builds(job_name)
    JenkinsCli.logger.debug("GET /job/#{job_name}")
    client.api_get_request(
      "/job/#{job_name}",
      "tree=name,url,upstreamProjects[name],downstreamProjects[name],culprits[absoluteUrl],allBuilds[number,url,result,timestamp,duration,actions[causes[shortDescription,userId,userName,upstreamBuild,upstreamProject],parameters[name,value]]]"
    )
  end

  def fetch_runs(job_name, build_number)
    JenkinsCli.logger.debug("GET /job/#{job_name}")
    client.api_get_request(
      "/job/#{job_name}/#{build_number}",
      "tree=runs[number,url,result,builtOn,timestamp,duration,artifacts[relativePath],failCount,skipCount,totalCount,urlName]"
    )["runs"] || []
  end

  def get_cached_build(job, number)
    if jobs[job]
      jobs[job]["allBuilds"].find { |b| b["number"] == number }
    else
      { "job" => job, "number" => number, "url" => "#{server_url}/job/#{job}/#{number}", "jobDeleted" => true }
    end
  end

  def load_job(name)
    return jobs[name] if jobs[name]

    #
    # Load the job, its upstream and downstreams, and all its builds
    #
    jobs[name] = fetch_job_and_builds(name)
    jobs[name]["allBuilds"] = jobs[name]["allBuilds"].sort_by { |b| b["number"].to_i }.reverse
    jobs[name]["allBuilds"].map! { |build| normalize_build(build) }

    # Load all upstream and downstream projects
    jobs[name]["downstreamProjects"].each { |job| load_job(job["name"]) }
    jobs[name]["upstreamProjects"].each { |job| load_job(job["name"]) }

    jobs[name]
  end

  def normalize_build(build)
    # extract job name from build URL: /job/chef-build/423
    path = URI(build["url"]).path
    build["number"] = File.basename(path).to_i
    build["job"] = File.basename(File.dirname(path))

    # Normalize timestamps
    build["timestamp"] = timestamp_to_datetime(build["timestamp"])
    build["duration"] = duration_to_time(build["duration"])

    # Pull stuff out of actions into the top level
    build.merge!(actions_to_hash(build.delete("actions")))

    # format parameters for easier use
    build["parameters"] = parameters_to_hash(build["parameters"])

    if build["culprits"]
      build["culprits"] = build["culprits"].map { |c| c["absoluteUrl"] && File.basename(c["absoluteUrl"]) }.compact
      build.delete("culprits") if build["culprits"].empty?
    end

    # Make the most important information appear at the top
    build = { "url" => nil, "result" => nil, "timestamp" => nil, "duration" => nil }.merge(build)

    # Interpret causes (retries vs. upstreams)
    if build["causes"]
      build["causes"].reject! do |cause|
        # Strip upstream causes out of the build and add them to pipeline linkage.
        # The information will be implicitly contained in the ordering of the
        # build_stages array when we're all done.
        if cause["upstreamBuild"]
          # If the upstream is the same job, we are a retry of the upstream
          if cause["upstreamProject"] == build["job"]
            build["retryOf"] ||= []
            build["retryOf"] |= [ cause["upstreamBuild"].to_i ]
          else
            build["upstreams"] ||= []
            build["upstreams"] |= [{
              "job" => cause["upstreamProject"],
              "number" => cause["upstreamBuild"].to_i
            }]
          end
          true

        # Remove empty causes (can happen due to tree weirdness)
        elsif cause.empty?
          true
        end
      end
      build.delete("causes") if build["causes"].empty?
    end

    build
  end

  def normalize_run(run)
    # Normalize timestamps
    run["timestamp"] = timestamp_to_datetime(run["timestamp"])
    run["duration"] = duration_to_time(run["duration"])

    # Pull stuff out of actions into the top level
    run.merge!(actions_to_hash(run.delete("actions")))

    run
  end

  # "actions" : [
  #   {
  #     "parameters" : [
  #       {
  #         "name" : "OMNIBUS_BUILD_VERSION",
  #         "value" : "12.10.42+20160510150801"
  #       },
  #     ]
  #   },
  #   ...
  # ]
  def actions_to_hash(actions)
    actions ||= {}

    result = {}
    actions.each do |action|
      action.each do |key, value|
        if result[key].nil?
          result[key] = value
        elsif result[key].is_a?(Array) && value.is_a?(Array)
          result[key] += value
        else
          raise ParseError, "Multiple #{key} actions found with non-array types: #{result.inspect}, #{action.inspect}"
        end
      end
    end
    result
  end

  # "parameters" : [
  #   {
  #     "name" : "OMNIBUS_BUILD_VERSION",
  #     "value" : "12.10.42+20160510150801"
  #   },
  #   ...
  # ]
  def parameters_to_hash(parameters)
    result = {}
    parameters.each { |parameter| result[parameter["name"]] = parameter["value"] }
    result
  end

# 1462900986044 is "time since 1970 in milliseconds"
  def timestamp_to_datetime(timestamp)
    Time.at(timestamp.to_f / 1000.0).utc.to_datetime.to_s
  end

  # 13759911 is duration in milliseconds
  def duration_to_time(duration)
    duration.to_f / 1000.0
  end
end
