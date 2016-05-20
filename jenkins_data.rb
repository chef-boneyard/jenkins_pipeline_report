require_relative "jenkins_pipeline"
require "yaml"
require "fileutils"

class JenkinsData
  attr_reader :path
  attr_reader :jenkins

  def initialize(path=".", **options)
    @path = path
    @jenkins = JenkinsPipeline.new(options)
  end

  def refresh(force_refresh_all: false, force_refresh_runs: force_refresh_all, force_refresh_omnibus_timing: force_refresh_all)
    # Merge remote build information with local
    builds = get_builds(force_refresh_all: force_refresh_all, force_refresh_runs: force_refresh_runs, force_refresh_omnibus_timing: force_refresh_omnibus_timing)
    builds = builds.map { |build| process_build(build) }
    builds.each { |build| write_build(build) }
    builds
  end

  def load
    raise "#{job_path} does not exist! Cannot load local builds." unless File.directory?(job_path)

    builds = Dir.entries(job_path).map do |entry|
      next unless File.extname(entry) == ".yaml"
      filename = File.join(job_path, entry)
      build = YAML.load(IO.read(filename))
      desired_filename = build_filename(build)
      if filename != desired_filename
        if File.exist?(desired_filename)
          puts "Deleting #{filename} (#{desired_filename} already exists)..."
          # We will (or have already) encountered the desired version of this. Delete and skip.
          File.delete(filename)
          next
        else
          puts "Renaming #{filename} to #{desired_filename}"
          File.rename(filename, desired_filename)
        end
      end
      build
    end.compact
    builds.sort_by { |build| build_filename(build) }.reverse
  end

  private

  def job_path
    File.join(path, jenkins.job)
  end

  def build_filename(build)
    stage = build["stages"][jenkins.job]
    File.join(job_path, "#{Time.parse(stage["timestamp"]).strftime("%Y%m%d")}-#{File.basename(stage["url"])}.yaml")
  end

  def get_builds(force_refresh_all: false, force_refresh_runs: force_refresh_all, force_refresh_omnibus_timing: force_refresh_all)
    local_builds = load.each_with_object({}) do |build,hash|
      hash[build_filename(build)] = build
    end

    remote_builds = jenkins.builds.map do |build|
      # Get the build stages
      build = {
        "stages" => jenkins.build_stages(build).each_with_object({}) { |b, hash| hash[b["job"]] = b.dup }
      }

      build = process_build(build)

      # Merge with the local build (if any)
      local_build = local_builds.delete(build_filename(build))
      if local_build
        build = local_build.merge(build)
        build["stages"].each do |job, b|
          if local_build["stages"].has_key?(job) && local_build["stages"][job]["number"] == b["number"]
            build["stages"][job] = local_build["stages"][job].merge(b)
          end
        end
      end

      # Grab all run data if the build has changed, if build is in progress, or
      # if we're forcing refresh.
      if build != local_build || build["stages"].any? { |job,stage| stage["result"].nil? } || force_refresh_runs
        build["stages"].each do |job, stage|
          runs = jenkins.runs(stage)
          runs = runs.each_with_object({}) do |run,hash|
            configuration = run["configuration"]
            raise "Run #{configuration} showed up twice in #{b["url"]}!" if hash.has_key?(configuration)
            hash[configuration] = stage["runs"][configuration].merge(run) if stage["runs"] && stage["runs"][configuration]
          end
          stage["runs"] = runs
        end
      end

      # Add omnibus timing information
      build["stages"].each do |job, stage|
        stage["runs"].each do |configuration, run|
          if run["result"] == "SUCCESS"
            if !run.has_key?("omnibus_timing") || force_refresh_omnibus_timing
              run["omnibus_timing"] = process_omnibus_timing(run)
            end
          end
        end
      end

      build
    end

    result = (remote_builds + local_builds.values)
    result.sort_by! { |build| Time.parse(build["timestamp"]) }
    result.reverse!
    result
  end

  def process_build(build)
    # Calculate build info
    first_stage = build["stages"].values.first
    last_stage = build["stages"].values.last

    build["version"] = last_stage["parameters"]["OMNIBUS_BUILD_VERSION"] if last_stage["parameters"]
    build["git_commit"] = last_stage["parameters"]["GIT_COMMIT"] if last_stage["parameters"]
    build["result"] = last_stage["result"]
    build["timestamp"] = first_stage["timestamp"]
    build["duration"] = build["stages"].values.inject(0.0) { |sum,stage| sum += stage["duration"] }

    # Delete unnecessary data
    build["stages"].each_with_index do |(job, stage), index|
      %w{job number upstreams downstreams}.each { |key| stage.delete(key) }
    end

    # Calculate run fields
    build["stages"].each do |job, stage|
      if stage["runs"]
        stage["runs"].each do |configuration, run|
          # Calculate delay
          delay = Time.parse(run["timestamp"]) - Time.parse(stage["timestamp"])
          run["delay"] = delay

          run.delete("delay") if run["delay"] == 0.0
          %w{configuration job number artifacts}.each { |key| run.delete(key) }
        end
      end
    end

    # Summarize stage failure information
    build["stages"].each do |job, stage|
      if stage["runs"]
        failures = stage["runs"].reject { |c,r| r["result"].nil? || r["result"] == "SUCCESS" }
        if failures.any?
          stage["failures"] = categorize_run_types(failures.keys, stage["runs"].keys).join(",")
        end
      end
    end

    # Reorder build data for nicer printing
    reordered_build = {}
    %w{result timestamp duration version git_commit}.each do |k,hash|
      reordered_build[k] = build[k] if build.has_key?(k)
    end
    reordered_build.merge!(build)
    build = reordered_build

    # Reorder stage and run data for nicer printing
    build["stages"].each_with_index do |(job, stage), index|
      reordered_stage = {}
      %w{result failures timestamp duration url}.each do |k,hash|
        reordered_stage[k] = stage[k] if stage.has_key?(k)
      end
      reordered_stage.merge!(stage)

      build["stages"][job] = reordered_stage

      if stage["runs"]
        stage["runs"].each do |configuration, run|
          # Reorder run data for nicer printing
          reordered_run = {}
          %w{result timestamp duration delay builtOn url}.each do |k,hash|
            reordered_run[k] = run[k] if run.has_key?(k)
          end
          reordered_run.merge!(run)

          stage["runs"][configuration] = reordered_run
        end
      end
    end

    build
  end

  def write_build(build)
    # Write it out!
    filename = build_filename(build)
    desired_output = YAML.dump(build)
    unless File.exist?(filename) && IO.read(filename) == desired_output
      puts "Writing #{filename} ..."
      FileUtils.mkdir_p(File.dirname(filename))
      IO.write(filename, desired_output)
    end
  end

  def process_omnibus_timing(run)
    path = URI(File.join(run["url"], "consoleText")).path
    puts "Processing #{path} ..."

    # Get the console log
    console_text = jenkins.client.api_get_request(path, nil, nil, true).body

    # Look for timing information
    result = {}
    console_text.lines.each do |line|
      component, timestamp, log = line.split("|", 3).map { |s| s.strip }
      if component =~ /^\[Builder:\s+(.+)\]\s+\S+$/i
        component = $1
        # [Builder: chef] I | 2016-05-11T20:29:35+00:00 | Build chef: 76.4841s
        if log =~ /^\s*Build #{component}:\s+(\d+(\.\d+)?)s$/
          result[component] = $1.to_f
        end
      else
        # [Packager::BFF] I | 2016-05-12T22:28:49+00:00 | Packaging time: 376.521s
        if log =~ /^\s*(Health check|Packaging) time:\s+(\d+(\.\d+)?)s$/
          result[$1] = $2.to_f
        end
      end
    end
    result
  end

  def categorize_run_types(run_types, all_run_types)
    # Categorize runs so that if everything fails, we just say "all"
    # To do this, categorize all the runs by what OS they are from:
    os_categories = all_run_types.group_by { |type| type.split("-")[0] }
    run_categories = {}
    run_categories["all"] = all_run_types - [ "acceptance" ]
    run_categories["unix"] = os_categories.reject { |c,t| c == "windows" }.values.flatten
    run_categories["linux"] = os_categories.reject { |c,t| %w{aix solaris bsd windows}.include?(c) }.values.flatten
    run_categories["bsd"] = os_categories.select { |c,t| c =~ /bsd/ }.values.flatten
    run_categories.merge!(os_categories)
    run_categories.each do |category, types|
      next if types.empty?
      # If every type in the category is in run_types, replace those types with the category
      if (types - run_types).empty?
        run_types = run_types - types + [ category ]
      end
    end
    run_types.sort.uniq
  end
end
