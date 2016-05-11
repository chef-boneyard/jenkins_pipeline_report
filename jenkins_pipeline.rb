require "uri"
require "pathname"

class JenkinsPipeline
  attr_reader :client
  attr_reader :name

  def initialize(client, name)
    @client = client
    @name = name
    load_job(name)
  end

  def jobs
    @jobs ||= {}
  end

  def builds
    jobs[name]["allBuilds"].map do |build|
      # Return the upstream-most build (the trigger).
      while build["upstreamBuilds"] && build["upstreamBuilds"].any?
        build = build["upstreamBuilds"].first
      end
      build
    end
  end

  def downstream_builds(build)
    result = [ build ]
    result += build["downstreamBuilds"].flat_map { |b| downstream_builds(b) } if build["downstreamBuilds"]
    result.uniq
  end

  def runs(build)
    build["runs"] ||= begin
      job_name = Pathname(URI(build["url"]).path).dirname.basename.to_s
      runs = client.api_get_request(
        "/job/#{job_name}/#{build["number"]}",
        "tree=runs[number,url,result]"
      )["runs"] || []
      runs.each { |run| run.merge!("configuration" => Pathname(URI(run["url"]).path).dirname.basename.to_s) }
      runs.sort_by { |run| run["configuration"] }
    end
    build["runs"]
  end

  def classify_run(run)
    params = {}
    run["configuration"].split(",").each do |name_value|
      name, value = name_value.split("=", 2)
      params[name] = value
    end
    case params["role"]
    when "builder", "tester"
      result = params["platform"]
      result << "-#{params["architecture"]}" unless params["architecture"] == "x86_64"
      result
    else
      params.values.join("-")
    end
  end

  private

  def load_job(name)
    return jobs[name] if jobs[name]

    #
    # Load the job, its upstream and downstreams, and all its builds
    #
    jobs[name] = client.api_get_request(
      "/job/#{name}",
      "tree=name,url,upstreamProjects[name],downstreamProjects[name],allBuilds[number,url,result,timestamp,actions[causes[upstreamBuild,upstreamProject]]]"
    )
    jobs[name]["allBuilds"] = jobs[name]["allBuilds"].sort_by { |b| b["number"].to_i }.reverse

    # Load all upstream and downstream projects
    jobs[name]["downstreamProjects"].each { |job| load_job(job["name"]) }
    jobs[name]["upstreamProjects"].each { |job| load_job(job["name"]) }

    # Link downstreams and upstreams
    jobs[name]["allBuilds"].each do |build|
      build["job"] = name
      causes = build["actions"].flat_map { |action| action["causes"] || [] }
      causes.each do |cause|
        if cause["upstreamProject"]
          upstream_job = jobs[cause["upstreamProject"]]
          if upstream_job
            upstream_build = upstream_job["allBuilds"].find { |b| b["number"] == cause["upstreamBuild"].to_i }
            build["upstreamBuilds"] ||= []
            build["upstreamBuilds"] << build
            upstream_build["downstreamBuilds"] ||= []
            upstream_build["downstreamBuilds"] << build
          else
            # job is so old it doesn't exist :()
          end
        end
      end
    end

    jobs[name]
  end
end
