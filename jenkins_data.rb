require_relative "jenkins_pipeline"
require "yaml"
require "fileutils"

class JenkinsData
  attr_reader :path
  attr_reader :jenkins

  def initialize(path=".", **jenkins_options)
    @path = path
    @jenkins = JenkinsPipeline.new(jenkins_options)
  end

  # Uncomment the puts message here to start showing progress info
  def self.debug(message)
#    puts message
  end

  def refresh(force_refresh_runs: false, force_refresh_logs: false, force_reprocess_logs: false)
    builds = refresh_builds
    builds.each do |build|
      JenkinsData.debug "Processing #{build["stages"].values.first["url"]} ..."
      refresh_runs(build, force: force_refresh_runs)
      cache_console_texts(build, force: force_refresh_logs)
      process_console_texts(build, force: force_reprocess_logs)
      cache_build(build)
    end
    builds
  end

  def refresh_builds
    # Merge remote build information with local
    builds = merge_builds(load, fetch_builds)
    builds.sort_by! { |build| Time.parse(build["timestamp"]) }
    builds.reverse!
    builds
  end

  def refresh_runs(build, force: false)
    return if build["missingFromJenkins"]
    build["stages"].each do |job,stage|
      if !stage.has_key?("runs") || in_progress?(stage) || force
        # Fetch run data for each build and merge into the stages
        runs = {}
        fetch_runs(stage).each do |configuration,remote_run|
          run = merge_run(stage["runs"][configuration], remote_run)
          runs[configuration] = run
        end
        stage["runs"] = runs
      end
    end
  end

  def cache_console_texts(build, force: false)
    return if build["missingFromJenkins"]
    build["stages"].each do |job,stage|
      stage["runs"].each do |configuration,run|
        cache_console_text(build, run, force: force)
      end
    end
  end

  def process_console_texts(build, force: false)
    build["stages"].each do |job,stage|
      stage["runs"].each do |configuration,run|
        process_console_text(build, run, force: force)
      end
    end
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

      # Fix up the keys of any runs, if our algorithm for configuration keys has changed
      build["stages"].each do |job, stage|
        rewritten_runs = {}
        stage["runs"].each_value do |run|
          job, build_number, configuration = jenkins.parse_run_url(run["url"])
          rewritten_runs[configuration] = run
        end
        stage["runs"] = rewritten_runs
      end

      build = process_build(build)

      build
    end.compact
    builds.sort_by { |build| build["timestamp"] }.reverse
  end

  def console_text(build, run)
    filename = console_text_filename(build, run)
    if File.exist?(filename)
      IO.binread(filename)
    elsif build["missingFromJenkins"]
      # TODO when we have a warning system, warn
      # warn "Console logs for #{build["data"]} are no longer in Jenkins! Cannot fetch."
    end
  end

  # Tell if a build, stage or run succeeded
  def succeeded?(obj)
    obj["result"] == "SUCCESS"
  end
  def self.succeeded?(obj)
    obj["result"] == "SUCCESS"
  end
  # Tell if a build, stage or run is in progress
  def in_progress?(obj)
    obj["result"].nil?
  end
  def self.in_progress?(obj)
    obj["result"].nil?
  end
  # Tell if a build, stage or run failed (i.e. is not in progress or successful)
  def failed?(obj)
    !succeeded?(obj) && !in_progress?(obj)
  end
  def self.failed?(obj)
    !succeeded?(obj) && !in_progress?(obj)
  end

  private

  #
  # Builds
  #

  def fetch_builds
    jenkins.builds.map { |build| normalize_build(build) }
  end

  def merge_builds(local_builds, remote_builds)
    remote_builds = remote_builds.map do |remote_build|
      # Grab the corresponding local build (if any)
      local_build = local_builds.select { |local_build| build_filename(remote_build) == build_filename(local_build) }.first
      if local_build
        local_builds.delete(local_build) if local_build
        # This is definitely in Jenkins
        local_build.delete("missingFromJenkins")
      end
      merge_build(local_build, remote_build)
    end
    # Mark the remaining builds as missing from jenkins
    local_builds.each do |local_build|
      local_build["missingFromJenkins"] = true
    end
    remote_builds + local_builds
  end

  def merge_build(local_build, remote_build)
    local_build ||= { "stages" => {} }
    remote_build ||= { "stages" => {} }
    build = local_build.merge(remote_build)
    if remote_build["stages"]
      build["stages"] = {}
      remote_build["stages"].each do |job,remote_stage|
        local_stage = local_build["stages"][job]
        build["stages"][job] = merge_stage(local_stage, remote_stage)
      end
    end
    build["changedThisTime"] = true if build != local_build
    build
  end

  def merge_stage(local_stage, remote_stage)
    local_stage ||= { "runs" => {} }
    remote_stage ||= { "runs" => {} }
    stage = local_stage.merge(remote_stage)
    if remote_stage["runs"]
      stage["runs"] = {}
      remote_stage["runs"].each do |configuration,remote_run|
        local_run = local_stage["runs"][configuration]
        stage["runs"][configuration] = merge_run(local_run, remote_run)
      end
    end
    stage["changedThisTime"] = true if stage != local_stage
    stage
  end

  def merge_run(local_run, remote_run)
    local_run ||= {}
    remote_run ||= {}
    run = local_run.merge(remote_run)
    run["changedThisTime"] = true if run != local_run
    run
  end

  def normalize_build(remote_build)
    # Get the build stages
    build = { "stages" => {} }
    jenkins.build_stages(remote_build).each do |stage|
      build["stages"][stage["job"]] = stage.dup
    end
    build = process_build(build)
    build
  end

  def process_build(build)
    # Process stages
    build["stages"].each do |job, stage|
      build["stages"][job] = process_stage(stage)
    end

    # Calculate build info
    first_stage = build["stages"].values.first
    last_stage = build["stages"].values.last

    # Add in calculated data
    build["version"] = last_stage["parameters"]["OMNIBUS_BUILD_VERSION"] if last_stage["parameters"]
    build["git_commit"] = last_stage["parameters"]["GIT_COMMIT"] if last_stage["parameters"]
    build["result"] = last_stage["result"]
    build["timestamp"] = first_stage["timestamp"]
    build["duration"] = build["stages"].values.inject(0.0) { |sum,stage| sum += stage["duration"] }

    # Reorder build data for nicer printing
    build = reorder_fields(build, %w{result timestamp duration version git_commit}, "stages")

    build
  end

  def process_stage(stage)
    # Process runs
    if stage["runs"]
      stage["runs"].each do |configuration, run|
        stage["runs"][configuration] = process_run(stage, run)
      end
    end

    # Delete unnecessary data
    %w{job number upstreams downstreams}.each { |key| stage.delete(key) }

    if stage["runs"]
      failures = stage["runs"].select { |c,r| failed?(r) }
      if failures.any?
        stage["failures"] = categorize_run_types(failures.keys, stage["runs"].keys).join(",")
      end
    end

    # Reorder fields for easier reading of YAML
    stage = reorder_fields(stage, %w{result failures timestamp duration url}, "runs")

    stage
  end

  #
  # Runs
  #

  def fetch_runs(stage)
    runs = {}
    jenkins.runs(stage).each do |run|
      job, build_number, configuration = jenkins.parse_run_url(run["url"])
      raise "Run #{configuration} showed up twice in #{stage["url"]}!" if runs.has_key?(configuration)
      runs[configuration] = process_run(stage, run)
    end
    runs
  end

  def process_run(stage, run)
    # Calculate delay
    delay = Time.parse(run["timestamp"]) - Time.parse(stage["timestamp"])
    run["delay"] = delay

    # convert omnibus_timing -> omnibusTiming
    if timing = run.delete("omnibus_timing")
      run["omnibusTiming"] = timing
    end

    run.delete("delay") if run["delay"] == 0.0
    %w{configuration job number artifacts}.each { |key| run.delete(key) }

    # Reorder run data for nicer printing
    run = reorder_fields(run, %w{result timestamp duration delay builtOn url})

    run
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

  #
  # Console Text
  #

  def cache_console_text(build, run, force: false)
    filename = console_text_filename(build, run)
    if !File.exist?(filename) || force || in_progress?(run) || run["changedThisTime"]
      console_text = fetch_console_text(run)
      unless File.exist?(filename) && console_text == IO.binread(filename)
        puts "Writing console text #{filename} ..."
        FileUtils.mkdir_p(File.dirname(filename))
        IO.binwrite(filename, console_text)
        run["changedThisTime"] = true
      end
    end
  end

  def fetch_console_text(run)
    path = URI(File.join(run["url"], "consoleText")).path
    JenkinsData.debug "GET #{path}"
    jenkins.client.api_get_request(path, nil, nil, true).body
  end

  def console_text_filename(build, run)
    job, build_number, configuration = jenkins.parse_run_url(run["url"])
    configuration.gsub!(/[^A-Za-z0-9\-]/, "_")
    File.join(build_directory(build), "#{job}-#{configuration}-#{build_number}.log")
  end

  def process_console_text(build, run, force: false)
    if run["changedThisTime"] || force || !run.has_key?("omnibusTiming")
      console_text = console_text(build, run)
      if console_text
        JenkinsData.debug("Process Console #{File.basename(console_text_filename(build, run))}...")
        extract_omnibus_timing(run, console_text)
      end
    end
  end

  def extract_omnibus_timing(run, console_text)
    # Look for timing information
    timing = {}
    console_text.lines.each do |line|
      component, timestamp, log = line.split("|", 3).map { |s| s.strip }
      if component =~ /^\[Builder:\s+(.+)\]\s+\S+$/i
        component = $1
        # [Builder: chef] I | 2016-05-11T20:29:35+00:00 | Build chef: 76.4841s
        if log =~ /^\s*Build #{component}:\s+(\d+(\.\d+)?)s$/
          timing[component] = $1.to_f
        end
      else
        # [Packager::BFF] I | 2016-05-12T22:28:49+00:00 | Packaging time: 376.521s
        if log =~ /^\s*(Health check|Packaging) time:\s+(\d+(\.\d+)?)s$/
          timing[$1] = $2.to_f
        end
      end
    end

    run["omnibusTiming"] = timing
  end

  #
  # Cache
  #
  def job_path
    File.join(path, jenkins.job)
  end

  def build_directory(build=nil)
    if build["stages"]
      stage = build["stages"][jenkins.job]
    else
      # we can be passed a remote or local build. this is a remote build.
      stage = build
    end
    File.join(job_path, "#{Time.parse(stage["timestamp"]).strftime("%Y%m%d")}-#{File.basename(stage["url"])}")
  end

  def build_filename(build)
    "#{build_directory(build)}.yaml"
  end

  def cache_build(build)
    # This is used internally but never written out
    build.delete("changedThisTime")
    build["stages"].each do |job,stage|
      stage.delete("changedThisTime")
      stage["runs"].each do |configuration,run|
        run.delete("changedThisTime")
      end
    end

    # Write it out!
    filename = build_filename(build)
    desired_output = YAML.dump(build)
    unless File.exist?(filename) && IO.read(filename) == desired_output
      puts "Writing #{filename} ..."
      FileUtils.mkdir_p(File.dirname(filename))
      IO.write(filename, desired_output)
    end
  end

  #
  # Helpers
  #

  def reorder_fields(hash, start_fields, end_fields=[])
    # Allow user to pass single field name, upconvert to array
    start_fields = Array(start_fields)
    end_fields = Array(end_fields)

    reordered_hash = {}
    # Put start_fields first
    start_fields.each do |field|
      reordered_hash[field] = hash[field] if hash.has_key?(field)
    end
    # Everything else next
    hash.each do |field, value|
      reordered_hash[field] = value unless start_fields.include?(field) || end_fields.include?(field)
    end
    # End fields last
    end_fields.each do |field|
      reordered_hash[field] = hash[field] if hash.has_key?(field)
    end
    reordered_hash
  end
end
