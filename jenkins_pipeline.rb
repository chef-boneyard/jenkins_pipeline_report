require "uri"
require "pathname"
require "jenkins_api_client"

class JenkinsPipeline
  attr_reader :client
  attr_reader :server_url
  attr_reader :job

  def initialize(server_url: "http://manhattan.ci.chef.co",
                 job: "chef-trigger-release",
                 identity_file: "~/.ssh/id_rsa",
                 **client_options)
    @server_url = server_url
    @job = job
    @client = JenkinsApi::Client.new(server_url: server_url, identity_file: identity_file, **client_options)

    puts "Jenkins at #{server_url} #{client.exec_cli("version")}"
    load_job(job)
  end

  #
  # The jobs involved in this pipeline.
  #
  def jobs
    @jobs ||= {}
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
    # Get the highest upstream of each build
    triggered_builds = jobs[job]["allBuilds"].map { |build| highest_upstream(build) }
    triggered_builds = triggered_builds.sort_by { |build| [ build["job"], build["number"] ] }.reverse.uniq

    # Bring in the downstreams for each build
    triggered_builds.map do |build|
      pipeline_build = [ build ]
      while build = most_recent_downstream(build)
        pipeline_build << build
      end
      pipeline_build
    end
  end

  #
  # Get all runs for the given build.
  #
  def runs(build)
    path = URI(build["url"]).path
    job_name = File.basename(File.dirname(path))
    build_number = File.basename(path)
    runs = get_runs(job_name, build_number)
    # Ridiculously, things get added into our matrix that aren't ours
    runs.reject! { |run| run["number"].to_i == build_number }
    runs.map! { |run| normalize_run(run) }
    runs.sort_by { |run| run["configuration"] }
  end

  private

  def add_upstream(build, job, number)
    # Add upstream links
    upstream_builds[build] ||= []
    upstream_builds[build] << [ job, number ]
    # Add downstream links
    downstream_builds[ [ job, number ] ] ||= []
    downstream_builds[ [ job, number ] ] << build
  end

  def downstream_builds(build=nil)
    @downstream_builds ||= {}
    if build
      @downstream_builds[[ build["job"], build["number"] ]]
    else
      @downstream_builds
    end
  end

  def upstream_builds(build = nil)
    @upstream_builds ||= {}
    if build
      # When we map upstreams the job may or may not actually exist.
      if @upstream_builds.has_key?(build)
        @upstream_builds[build].map { |job, number| get_cached_build(job, number) }
      else
        nil
      end
    else
      @upstream_builds
    end
  end

  def highest_upstream(build)
    # Find the first upstream
    while upstreams = upstream_builds(build)
      if upstreams.size > 1
        raise "Multiple upstreams for build #{build["url"]}: #{upstreams.inspect}"
      end
      build = upstreams.first
    end
    build
  end

  def most_recent_downstream(build)
    downstreams = downstream_builds(build)
    return nil unless downstreams

    # There may have been retries. Pick the most recent downstream as the
    # canonical one (the last retry).
    if downstreams.map { |b| b["job"] }.uniq.size > 1
      raise "Build #{build["url"]} has multiple downstreams from different jobs (#{downstreams.map { |b| b["url"] }.join(", ")})! We don't handle pipelines like that ..."
    end
    downstreams = downstreams.sort_by { |b| b["timestamp"] }
    latest_build = downstreams.first
    latest_build["retries"] = downstreams.map { |b| b["number"] } if downstreams.size > 1
    latest_build
  end

  def get_job_and_builds(job_name)
    client.api_get_request(
      "/job/#{job_name}",
      "tree=name,url,upstreamProjects[name],downstreamProjects[name],allBuilds[number,url,result,timestamp,duration,actions[causes[shortDescription,userId,userName,upstreamBuild,upstreamProject],parameters[name,value]]]"
    )
  end

  def get_runs(job_name, build_number)
    client.api_get_request(
      "/job/#{job_name}/#{build_number}",
      "tree=runs[number,url,result,builtOn,timestamp,duration,artifacts[relativePath],failCount,skipCount,totalCount,urlName]"
    )["runs"] || []
  end

  def get_cached_build(job, number)
    if jobs[job]
      jobs[job]["allBuilds"].find { |b| b["number"] == number }
    else
      { "job" => job, "number" => number, "url" => "#{server_url}/job/#{job}/#{number}", "jobDeleted" => true, "timestamp" => build["timestamp"] }
    end
  end

  def load_job(name)
    return jobs[name] if jobs[name]

    #
    # Load the job, its upstream and downstreams, and all its builds
    #
    jobs[name] = get_job_and_builds(name)
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

    # Make the most important information appear at the top
    build = { "url" => nil, "result" => nil, "timestamp" => nil, "duration" => nil }.merge(build)

    return build unless build["causes"]

    if build["causes"]
      # Strip upstream causes out of the build and add them to pipeline linkage.
      # The information will be implicitly contained in the ordering of the
      # pipeline_build array when we're all done.
      build["causes"].reject! do |cause|
        if cause["upstreamBuild"]
          add_upstream(build, cause["upstreamProject"], cause["upstreamBuild"].to_i)
          true
        end
      end
      build.delete("causes") if build["causes"].empty?
    end

    build
  end

  def normalize_run(run)
    # Extract pertinent data from URL
    # /job/chef-test/342/architecture=x86_64,platform=acceptance,project=chef,role=tester
    path = URI(run["url"]).path
    run["job"] = File.basename(File.dirname(File.dirname(path)))
    build_number = File.basename(File.dirname(path))
    configuration_str = File.basename(path)
    # Check for alternate URL type:
    # /job/chef-test/architecture=x86_64,platform=acceptance,project=chef,role=tester/342
    unless build_number =~ /^\d+$/
      build_number, configuration_str = configuration_str, build_number
    end
    run["number"] = build_number.to_i

    # Normalize timestamps
    run["timestamp"] = timestamp_to_datetime(run["timestamp"])
    run["duration"] = duration_to_time(run["duration"])

    # Pull stuff out of actions into the top level
    run.merge!(actions_to_hash(run.delete("actions")))

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
      configuration_summary = run["configuration"]
    end
    run["configuration"] = configuration_summary

    # Make the most important information appear at the top
    run = { "url" => nil, "result" => nil, "configuration" => nil }.merge(run)
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
          raise "Multiple #{key} actions found with non-array types: #{result.inspect}, #{action.inspect}"
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
    Time.at(timestamp.to_f / 1000.0).to_datetime.to_s
  end

  # 13759911 is duration in milliseconds
  def duration_to_time(duration)
    duration.to_f / 1000.0
  end
end
