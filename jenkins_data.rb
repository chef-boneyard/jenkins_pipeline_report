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
    puts message
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
        process_console_text(build, configuration, run, force: force)
      end
      process_stage(stage)
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
      failures = stage["runs"].select { |c,run| failed?(run) }
      if failures.any?
        failures = failures.group_by { |c,run| (run["failureCause"] && run["failureCause"]["detailedCause"]) || "unknown" }
        failures.each do |cause, causedFailures|
          configurations = causedFailures.map { |configuration,run| configuration }
          failures[cause] = categorize_run_types(configurations, stage["runs"].keys).join(",")
        end
        stage["failures"] = failures
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

  def process_console_text(build, configuration, run, force: false)
    if run["changedThisTime"] || force ||
       !run.has_key?("omnibusTiming") ||
       (configuration == "acceptance" && !run.has_key?("acceptanceTiming"))
      JenkinsData.debug("Extracting timing from #{File.basename(console_text_filename(build, run))}...")
      console_text ||= console_text(build, run)
      return unless console_text
      extract_timing(configuration, run, console_text)
    end

    if run["changedThisTime"] || force || !run.has_key?("failureCause")
      if failed?(run)
        JenkinsData.debug("Extracting failure reason from #{File.basename(console_text_filename(build, run))}...")
        console_text ||= console_text(build, run)
        return unless console_text
        extract_failure_information(run, console_text)
      end
    end

    #
    # Decide on a cause using heuristics
    #
    deduce_cause(run)
    if run["failureCause"]
      run["failureCause"] = reorder_fields(run["failureCause"], %w{cause detailedCause shellCommand stacktrace jenkinsBuildStep})
    end
  end

  def extract_timing(configuration, run, console_text)
    # Look for timing information
    omnibus_timing = {}
    acceptance_timing = []
    lines = console_text.lines
    index = lines.size-1
    while index >= 0
      line = lines[index]
      if line =~ /^CHEF-ACCEPTANCE::\[[^\]]+\]\s+\|(.+)\|\s*$/
        index, results = extract_chef_acceptance_result(lines, index)
        acceptance_run = {}
        results.each do |result|
          acceptance_run[result["suite"]] ||= {}
          acceptance_run[result["suite"]][result["command"]] = result["duration"]
        end
        acceptance_timing << acceptance_run

      else
        component, timestamp, log = line.split("|", 3).map { |s| s.strip }
        if component =~ /^\[Builder:\s+(.+)\]\s+\S+$/i
          component = $1
          # [Builder: chef] I | 2016-05-11T20:29:35+00:00 | Build chef: 76.4841s
          if log =~ /^\s*Build #{component}:\s+(\d+(\.\d+)?)s$/
            omnibus_timing[component] = $1.to_f
          end
        else
          # [Packager::BFF] I | 2016-05-12T22:28:49+00:00 | Packaging time: 376.521s
          if log =~ /^\s*(Health check|Packaging) time:\s+(\d+(\.\d+)?)s$/
            omnibus_timing[$1] = $2.to_f
          end
        end
      end

      index -= 1
    end

    run["omnibusTiming"] = omnibus_timing
    run["acceptanceTiming"] = acceptance_timing if configuration == "acceptance" || acceptance_timing.any?
  end

  def extract_failure_information(run, console_text)
    reason = {}
    lines = console_text.lines
    index = lines.size - 1
    while index > 0
      line = lines[index]
      # Build step 'Invoke XShell command' marked build as failure
      case line
      when /^\s*Build step '(.+)' (marked build as|changed build result to) failure\s*$/i
        reason["jenkinsBuildStep"] ||= $1

      when /^\s*(\S+)(:\d+:in `.+')\s*$/
        index, stacktrace = extract_stacktrace(lines, index)
        reason["stacktrace"] ||= stacktrace if stacktrace.any?

      when /^The following shell command exited with status (\d+):\s/
        command = extract_shell_command(lines, index, $1)
        reason["shellCommand"] ||= command if command

      when /^\s*Verification of component '(.+)' failed.\s*$/
        reason["tests"] ||= {}
        reason["tests"]["chef_verify"] ||= []
        reason["tests"]["chef_verify"] << $1

      when /^CHEF-ACCEPTANCE::\[[^\]]+\]\s+\|(.+)\|\s*$/
        index, results = extract_chef_acceptance_result(lines, index)
        failures = results.select { |result| result["error"] == "Y" && result["command"] != "Total" }
        if failures.any?
          reason["tests"] ||=  {}
          reason["tests"]["chef-acceptance"] ||= []
          failures.each do |failure|
            reason["tests"]["chef-acceptance"] << "#{failure["suite"]} (#{failure["command"]})"
          end
        end

      when /The --deployment flag requires a/
        joined = "#{line.strip} #{lines[index+1].strip}"
        if joined =~ /The --deployment flag requires a .*Gemfile.lock/
          reason["suspiciousLines"] ||= []
          reason["suspiciousLines"] << joined
        end

      when /EACCES/,
           /Permission denied/i
        reason["suspiciousLines"] ||= []
        reason["suspiciousLines"] << line.strip
      end

      unless reason.has_key?("omnibusStep")
        component, timestamp, log = line.split("|", 3).map { |s| s.strip }
        if log && component =~ /^\[\s+(.+)\]\s+\S+$/i
          component = $1
          reason["omnibusStep"] ||= component
        end
      end

      index -= 1
    end

    run["failureCause"] = reason
  end

  def extract_chef_acceptance_result(lines, index)
    # CHEF-ACCEPTANCE::[2016-05-13 20:19:04 +0000] chef-acceptance run succeeded
    # CHEF-ACCEPTANCE::[2016-05-13 20:19:04 +0000] | Suite   | Command   | Duration | Error |
    # CHEF-ACCEPTANCE::[2016-05-13 20:19:04 +0000] | trivial | provision | 00:01:21 | N     |
    # CHEF-ACCEPTANCE::[2016-05-13 20:19:04 +0000] | trivial | verify    | 00:00:15 | N     |
    # CHEF-ACCEPTANCE::[2016-05-13 20:19:04 +0000] | trivial | destroy   | 00:00:07 | N     |
    # CHEF-ACCEPTANCE::[2016-05-13 20:19:04 +0000] | trivial | Total     | 00:01:58 | N     |
    # CHEF-ACCEPTANCE::[2016-05-13 20:19:04 +0000] | Run     | Total     | 00:01:58 | N     |
    rows = []
    while lines[index] =~ /^CHEF-ACCEPTANCE::\[[^\]]+\]\s+\|(.+)\|\s*$/
      rows.unshift($1.split("|").map { |f| f.strip })
      index -= 1
      line = lines[index]
    end
    field_names = rows.shift.map { |name| name.downcase }
    results = []
    rows.each do |row|
      results << Hash[field_names.zip(row)]
    end
    [ index + 1, results ]
  end

  def deduce_cause(run)
    reason = run["failureCause"]
    if failed?(run) && run["result"].downcase != "failure"
      reason ||= run["failureCause"] = {}
      reason["cause"] = run["result"].downcase
      reason["detailedCause"] = reason["cause"]
      return
    end

    if reason
      if reason["tests"]
        reason["cause"] = "#{reason["tests"].keys.join(",")}"
        reason["detailedCause"] = reason["tests"].map do |test_type, t|
          if t.size <= 3
            "#{test_type}[#{t.join(",")}]"
          else
            test_type
          end
        end.join(",")
      end

      if reason["shellCommand"]
        case reason["shellCommand"]["stderr"]
        when /Failed to connect to (.+) port (\d+): Timed out/i,
             /Failed connect to (.+):(\d+); (Operation|Connection) (timed out|now in progress)/i
          reason["cause"] = "network timeout"
          reason["detailedCause"] = "network timeout reaching #{$1}:#{$2}"
          return
        end

        case reason["shellCommand"]["stdout"]
        when /Gemfile\.lock is corrupt/
          reason["cause"] = "corrupt Gemfile.lock"
          reason["detailedCause"] = reason["cause"]
        end
      end

      if reason["suspiciousLines"]
        reason["suspiciousLines"].each do |suspiciousLine|
          case suspiciousLine
          when /The --deployment flag requires a .*\/([^\/]+\/Gemfile.lock)/
            reason["cause"] = "missing Gemfile.lock"
            reason["detailedCause"] = "missing #{$1}"

          when /(EACCES)/,
               /java.io.FileNotFoundException.*(Permission denied)/
            reason["cause"] = "disk space"
            reason["detailedCause"] = "disk space (#{$1})"
          end
        end
      end
    end
  end

  # /home/jenkins/workspace/chefdk-build/architecture/x86_64/platform/debian-6/project/chefdk/role/builder/omnibus/vendor/bundle/ruby/2.1.0/bundler/gems/omnibus-7c98e2bbceb7/lib/omnibus/util.rb:101:in `rescue in shellout!'
  #   /home/jenkins/workspace/chefdk-build/architecture/x86_64/platform/debian-6/project/chefdk/role/builder/omnibus/vendor/bundle/ruby/2.1.0/bundler/gems/omnibus-7c98e2bbceb7/lib/omnibus/util.rb:97:in `shellout!'
  #   /home/jenkins/workspace/chefdk-build/architecture/x86_64/platform/debian-6/project/chefdk/role/builder/omnibus/vendor/bundle/ruby/2.1.0/bundler/gems/omnibus-7c98e2bbceb7/lib/omnibus/fetchers/git_fetcher.rb:263:in `revision_from_remote_reference'
  #   /home/jenkins/workspace/chefdk-build/architecture/x86_64/platform/debian-6/project/chefdk/role/builder/omnibus/vendor/bundle/ruby/2.1.0/bundler/gems/omnibus-7c98e2bbceb7/lib/omnibus/fetchers/git_fetcher.rb:237:in `resolve_version'
  #   /home/jenkins/workspace/chefdk-build/architecture/x86_64/platform/debian-6/project/chefdk/role/builder/omnibus/vendor/bundle/ruby/2.1.0/bundler/gems/omnibus-7c98e2bbceb7/lib/omnibus/fetcher.rb:186:in `resolve_version'
  #   /home/jenkins/workspace/chefdk-build/architecture/x86_64/platform/debian-6/project/chefdk/role/builder/omnibus/vendor/bundle/ruby/2.1.0/bundler/gems/omnibus-7c98e2bbceb7/lib/omnibus/software.rb:827:in `to_manifest_entry'
  #   /home/jenkins/workspace/chefdk-build/architecture/x86_64/platform/debian-6/project/chefdk/role/builder/omnibus/vendor/bundle/ruby/2.1.0/bundler/gems/omnibus-7c98e2bbceb7/lib/omnibus/software.rb:115:in `manifest_entry'
  #   /home/jenkins/workspace/chefdk-build/architecture/x86_64/platform/debian-6/project/chefdk/role/builder/omnibus/vendor/bundle/ruby/2.1.0/bundler/gems/omnibus-7c98e2bbceb7/lib/omnibus/software.rb:986:in `fetcher'
  #   /home/jenkins/workspace/chefdk-build/architecture/x86_64/platform/debian-6/project/chefdk/role/builder/omnibus/vendor/bundle/ruby/2.1.0/bundler/gems/omnibus-7c98e2bbceb7/lib/omnibus/software.rb:842:in `fetch'
  #   /home/jenkins/workspace/chefdk-build/architecture/x86_64/platform/debian-6/project/chefdk/role/builder/omnibus/vendor/bundle/ruby/2.1.0/bundler/gems/omnibus-7c98e2bbceb7/lib/omnibus/project.rb:1067:in `block (3 levels) in download'
  #   /home/jenkins/workspace/chefdk-build/architecture/x86_64/platform/debian-6/project/chefdk/role/builder/omnibus/vendor/bundle/ruby/2.1.0/bundler/gems/omnibus-7c98e2bbceb7/lib/omnibus/thread_pool.rb:64:in `call'
  #   /home/jenkins/workspace/chefdk-build/architecture/x86_64/platform/debian-6/project/chefdk/role/builder/omnibus/vendor/bundle/ruby/2.1.0/bundler/gems/omnibus-7c98e2bbceb7/lib/omnibus/thread_pool.rb:64:in `block (4 levels) in initialize'
  #   /home/jenkins/workspace/chefdk-build/architecture/x86_64/platform/debian-6/project/chefdk/role/builder/omnibus/vendor/bundle/ruby/2.1.0/bundler/gems/omnibus-7c98e2bbceb7/lib/omnibus/thread_pool.rb:62:in `loop'
  #   /home/jenkins/workspace/chefdk-build/architecture/x86_64/platform/debian-6/project/chefdk/role/builder/omnibus/vendor/bundle/ruby/2.1.0/bundler/gems/omnibus-7c98e2bbceb7/lib/omnibus/thread_pool.rb:62:in `block (3 levels) in initialize'
  #   /home/jenkins/workspace/chefdk-build/architecture/x86_64/platform/debian-6/project/chefdk/role/builder/omnibus/vendor/bundle/ruby/2.1.0/bundler/gems/omnibus-7c98e2bbceb7/lib/omnibus/thread_pool.rb:61:in `catch'
  #   /home/jenkins/workspace/chefdk-build/architecture/x86_64/platform/debian-6/project/chefdk/role/builder/omnibus/vendor/bundle/ruby/2.1.0/bundler/gems/omnibus-7c98e2bbceb7/lib/omnibus/thread_pool.rb:61:in `block (2 levels) in initialize'
  def extract_stacktrace(lines, index)
    stacktrace = []

    while index >= 0
      line = lines[index]
      if line =~ /^\s*(\S+)(:\d+:in `.+')\s*$/
        filename, rest_of_line = $1, $2
        if filename =~ /\/architecture\/[^\/]+\/platform\/[^\/]+\/project\/[^\/]+\/role\/[^\/]+\/(.+)/
          line = "#{$1}#{rest_of_line}"
        end
        # skip the top if it's thread pool stuff
        unless filename.end_with?("thread_pool.rb") && stacktrace.empty?
          stacktrace << line.strip
        end
      else
        break
      end
      index -= 1
    end

    [ index+1, stacktrace.reverse ]
  end

  def extract_shell_command(lines, index, exit_status)
    start_index = index
    command = { "exitStatus" => exit_status }

    # The following shell command exited with status 128:
    index += 1

    #
    #     $ git ls-remote "http://git.savannah.gnu.org/r/config.git" "master*"
    index += 1 while lines[index].chomp == ""
    command["command"] = lines[index].strip
    index += 1
    # Get rid of the $
    command["command"] = $1 if command["command"] =~ /^\s*\$\s*(.+)/
    command["command"] = command["command"].strip

    #
    # Output:
    #
    #     (nothing)
    #
    # Error:
    index += 1 while lines[index].strip == ""
    unless lines[index].chomp == "Output:"
      return nil
    end
    index += 1
    index += 1 while lines[index].chomp == ""
    return nil unless lines[index].start_with?("    ")
    command["stdout"] = lines[index][4..-1]
    index += 1
    while lines[index].chomp != "Error:"
      command["stdout"] << lines[index]
      index += 1
    end
    command["stdout"] = command["stdout"].strip
    command.delete("stdout") if command["stdout"] == "(nothing)"

    # Error:
    #
    #     fatal: unable to access 'http://git.savannah.gnu.org/r/config.git/': Failed connect to git.savannah.gnu.org:80; Operation now in progress
    index += 1
    index += 1 while lines[index].chomp == ""
    return nil unless lines[index].start_with?("    ")
    command["stderr"] = lines[index][4..-1]
    index += 1
    while lines[index].chomp != ""
      command["stderr"] << lines[index]
      index += 1
    end
    command["stderr"] = command["stderr"].strip
    command.delete("stderr") if command["stderr"] == "(nothing)"

    command
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
