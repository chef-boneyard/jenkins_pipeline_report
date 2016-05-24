require_relative "jenkins_pipeline"
require_relative "failure_extractor"
require_relative "timing_extractor"
require_relative "jenkins_helpers"
require "psych"
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
    puts message
  end

  def builds(local: false, **options)
    builds = load
    # Merge remote build information with local
    builds = merge_builds(load, fetch_builds) unless local
    builds.sort_by! { |build| Time.parse(build["timestamp"]) }
    builds.reverse!

    builds.each do |build|
      refresh_build(build, **options)
    end

    builds
  end

  def refresh_build(build, force_refresh_runs: false, force_refresh_logs: false, force_reprocess_logs: false)
    JenkinsData.debug "Processing #{build["stages"].values.last["url"]} ..."
    refresh_runs(build, force: force_refresh_runs)
    cache_console_texts(build, force: force_refresh_logs)
    process_console_texts(build, force: force_reprocess_logs)
    cache_build(build)
  end

  def refresh_runs(build, force: false)
    return if build["missingFromJenkins"]
    build["stages"].each do |job,stage|
      if !stage.has_key?("runs") || in_progress?(stage) || force
        # Fetch run data for each build and merge into the stages
        runs = {}
        fetch_runs(stage).each do |configuration,remote_run|
          run = remote_run
          run = merge_run(stage["runs"][configuration], remote_run) if stage["runs"]
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
        process_console_text(build, configuration, run, force: force)
      end
      process_stage(stage)
    end
  end

  def load
    return [] unless File.directory?(job_path)

    builds = Dir.entries(job_path).map do |entry|
      next unless File.extname(entry) == ".yaml"
      filename = File.join(job_path, entry)
      build = Psych.load(IO.read(filename))
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
    local_stage ||= {}
    remote_stage ||= {}
    stage = local_stage.merge(remote_stage)
    if remote_stage["runs"] && local_stage["runs"]
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
    # Reverse the stage order so last is first, to make it easier to see errors
    jenkins.build_stages(remote_build).reverse_each do |stage|
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
    first_stage = build["stages"].values.last
    last_stage = build["stages"].values.first

    # Add in calculated data
    build["version"] = last_stage["parameters"]["OMNIBUS_BUILD_VERSION"] if last_stage["parameters"]
    build["git_commit"] = last_stage["parameters"]["GIT_COMMIT"] if last_stage["parameters"]
    build["result"] = last_stage["result"]
    build["timestamp"] = first_stage["timestamp"]
    build["duration"] = build["stages"].values.inject(0.0) { |sum,stage| sum += stage["duration"] }

    # Reorder build data for nicer printing
    build = JenkinsHelpers.reorder_fields(build, %w{result timestamp duration version git_commit}, "stages")

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

    stage["retryOf"] = stage["retryOf"].sort.reverse if stage["retryOf"]

    if stage["runs"]
      failures = stage["runs"].select { |c,run| failed?(run) }
      if failures.any?
        failures = failures.group_by { |c,run| (run["failureCause"] && run["failureCause"]["detailedCause"]) || "unknown" }
        failures.each do |cause, causedFailures|
          configurations = causedFailures.map { |configuration,run| configuration }
          failures[cause] = categorize_run_types(configurations, stage["runs"].keys).join(",")
        end
        stage["failures"] = failures
      end

      # Reorder runs by failure first, then by configuration name
      stage["runs"] = Hash[stage["runs"].sort_by { |configuration,run| "#{failed?(run) ? 0 : 1}-#{configuration}" }]
    end

    # Reorder fields for easier reading of YAML
    stage = JenkinsHelpers.reorder_fields(stage, %w{result failures timestamp duration url}, "runs")

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
    run = JenkinsHelpers.reorder_fields(run, %w{result timestamp duration delay builtOn url})

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

  def process_console_text(build, configuration, run, force: false)
    if run["changedThisTime"] || force ||
       !run.has_key?("omnibusTiming") ||
       (configuration == "acceptance" && !run.has_key?("acceptanceTiming"))
      console_text ||= console_text(build, run)
      return unless console_text
      JenkinsData.debug("Extracting timing from #{File.basename(console_text_filename(build, run))}...")
      TimingExtractor.extract(configuration, run, console_text)
    end

    if run["changedThisTime"] || force || !run.has_key?("failureCause")
      if failed?(run)
        console_text ||= console_text(build, run)
        return unless console_text
        JenkinsData.debug("Extracting failure cause from #{File.basename(console_text_filename(build, run))}...")
        FailureExtractor.extract(build, run, console_text)
      end
    end

    #
    # Decide on a cause using heuristics
    #
    FailureExtractor.deduce_cause(run)
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
    desired_output = Psych.dump(build)
    unless File.exist?(filename) && IO.read(filename) == desired_output
      puts "Writing #{filename} ..."
      FileUtils.mkdir_p(File.dirname(filename))
      IO.write(filename, desired_output)
    end
  end

  def yaml_dump(y)
    visitor = Psych::Visitors::YAMLTree.create options
    visitor << o
    visitor.tree.yaml io, options
  end
end
