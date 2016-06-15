require_relative "jenkins_pipeline"
require_relative "log_extractor"
require_relative "failure_extractor"
require_relative "timing_extractor"
require_relative "helpers"
require_relative "cli"
require "psych"
require "fileutils"

module JenkinsPipelineReport
  class SummaryCache
    attr_reader :path
    attr_reader :jenkins_pipeline
    def logger
      jenkins_pipeline.logger
    end
    def job
      jenkins_pipeline.job
    end

    def initialize(path=".", logger:, **jenkins_options)
      @path = path
      @jenkins_pipeline = JenkinsPipeline.new(jenkins_options)
    end

    def builds(local: false, **options, &where)
      builds = load
      # Merge remote build information with local
      builds = merge_builds(builds, fetch_builds) unless local
      builds.select! { |build| where.call(build) } if where
      builds.sort_by! { |build| Time.parse(build["timestamp"]) }
      builds.reverse!

      Cli.logger.info("Refreshing builds ...")
      builds.each do |build|
        next if where && !where.call(build)
        refresh_build(build, **options)
      end

      builds
    end

    def refresh_build(build, force_refresh_runs: false, force_refresh_logs: false, force_reprocess_logs: false, force_resummarize: false)
      Cli.logger.info "Processing #{build["stages"].values.last["url"]} ..."
      refresh_runs(build, force: force_refresh_runs)
      cache_console_texts(build) if force_refresh_logs
      extract_console_texts(build, force: force_reprocess_logs)
      summarize_console_texts(build, force: force_resummarize)
      # Do one last reordering of everything
      build = process_build(build)
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

    def extract_console_texts(build, force: false)
      build["stages"].each do |job,stage|
        stage["runs"].each do |configuration,run|
          LogExtractor.extract(self, build, run, force: force)
        end
      end
    end

    def summarize_console_texts(build, force: false)
      build["stages"].each do |job,stage|
        stage["runs"].each do |configuration,run|
          TimingExtractor.extract(configuration, run, force: force)
          FailureExtractor.extract(run, force: force)
        end
      end
    end

    def load
      Cli.logger.info("Loading builds from #{job_path} ...")
      return [] unless File.directory?(job_path)

      builds = Dir.entries(job_path).map do |entry|
        next unless File.extname(entry) == ".yaml"
        filename = File.join(job_path, entry)
        Cli.logger.debug("Loading build #{filename} ...")
        build = Psych.load(IO.read(filename))
        desired_filename = build_filename(build)
        if filename != desired_filename
          logs = filename[0..-6]
          desired_logs = desired_filename[0..-6]
          if File.exist?(desired_filename)
            Cli.logger.info "Deleting #{filename} (#{desired_filename} already exists) ..."
            # We will (or have already) encountered the desired version of this. Delete and skip.
            File.delete(filename)

            if File.exist?(logs)
              if File.exist?(desired_logs)
                # Delete logs if they already exist
                Cli.logger.info "Deleting #{logs} (#{desired_logs} already exists) ..."
                FileUtils.rm_rf(logs)
              else
                # Carry logs over if we have no logs
                Cli.logger.info "Renaming #{logs} to #{desired_logs} ..."
                File.rename(logs, desired_logs)
              end
            end

            next
          else
            Cli.logger.info "Renaming #{filename} to #{desired_filename} ..."
            File.rename(filename, desired_filename)

            # Carry logs over as well
            if File.exist?(logs)
              # Delete logs if they are already there
              if File.exist?(desired_logs)
                Cli.logger.info "Deleting #{desired_logs} ..."
                FileUtils.rm_rf(desired_logs)
              end

              Cli.logger.info "Renaming #{logs} to #{desired_logs} ..."
              File.rename(logs, desired_logs)
            end
          end
        end

        # Fix up the keys of any runs, if our algorithm for configuration keys has changed
        build["stages"].each do |job, stage|
          rewritten_runs = {}
          stage["runs"].each_value do |run|
            job, build_number, configuration = jenkins_pipeline.parse_run_url(run["url"])
            rewritten_runs[configuration] = run
          end
          stage["runs"] = rewritten_runs
        end

        build = process_build(build)

        build
      end.compact
      builds.sort_by { |build| build["timestamp"] }.reverse
    end

    def console_text(build, run, force: false)
      filename = cache_console_text(build, run, force: force)
      if filename && File.exist?(filename)
        Cli.logger.debug("Reading log #{filename} ...")
        content = IO.binread(filename)
      end
      if build["missingFromJenkins"]
        # TODO when we have a warning system, warn
        # warn "Console logs for #{build["data"]} are no longer in Jenkins! Cannot fetch."
      end
      content
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
      Cli.logger.info("Fetching remote builds ...")
      jenkins_pipeline.builds.map { |build| normalize_build(build) }
    end

    def merge_builds(local_builds, remote_builds)
      local_builds = Hash[local_builds.map { |build| [build_filename(build), build] }]
      remote_builds = remote_builds.map do |remote_build|
        # Grab the corresponding local build (if any)
        remote_filename = build_filename(remote_build)
        local_build = local_builds[remote_filename]
        if local_build
          local_builds.delete(remote_filename)
          # This is definitely in Jenkins; correct the record if that used to be an issue
          local_build.delete("missingFromJenkins")
        end
        merge_build(local_build, remote_build)
      end
      # Mark the remaining builds as missing from jenkins
      local_builds.each_value do |local_build|
        local_build["missingFromJenkins"] = true
      end
      remote_builds + local_builds.values
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
      jenkins_pipeline.build_stages(remote_build).reverse_each do |stage|
        stage = stage.dup
        build["stages"][stage["job"]] = stage
        stage["retries"].map { |build| File.basename(build["url"]).to_i } if stage["retries"]
      end

      build = process_build(build)

      build
    end

    def process_build(build)
      # Process stages
      build["stages"].each do |job, stage|
        build["stages"][job] = process_stage(stage)
      end

      # Calculate parameters
      parameters = build["parameters"] || {}
      build["stages"].each do |job, stage|
        if stage["parameters"]
          parameters = stage["parameters"].merge(parameters)
          stage["parameters"].delete_if { |key, value| parameters[key] == value }
          stage.delete("parameters") if stage["parameters"].empty?
        end
      end
      build["parameters"] = Helpers.reorder_fields(parameters)

      # Calculate build info
      first_stage = build["stages"].values.last
      last_stage = build["stages"].values.first

      # Add in calculated data
      build["version"] = build["parameters"]["OMNIBUS_BUILD_VERSION"]
      build["git_ref"] = build["parameters"]["GIT_REF"]
      build["git_commit"] = build["parameters"]["GIT_COMMIT"]
      build["result"] = last_stage["result"]
      build["timestamp"] = first_stage["timestamp"]
      build["duration"] = build["stages"].values.inject(0.0) { |sum,stage| sum += stage["duration"] }
      triggered_by = first_stage["causes"].map { |cause| cause["userId"] }.compact.first if first_stage["causes"]
      build["triggeredBy"] = triggered_by if triggered_by
      build["url"] = build["stages"][jenkins_pipeline.job]["url"]

      # Summarize failures
      failures = {}
      build["stages"].each do |job,stage|
        if stage["failures"]
          stage["failures"].each do |category,configurations|
            failures["#{job} #{category}"] = configurations
          end
        end
      end
      if failures.any?
        build["failures"] = failures
      else
        build.delete("failures")
      end

      # Reorder build data for nicer printing
      build = Helpers.reorder_fields(build, %w{result timestamp duration triggeredBy url version git_ref git_commit}, %w{stages parameters})

      build
    end

    def process_stage(stage)
      stage["timestamp"] = Time.parse(stage["timestamp"]).utc.to_s

      # Process runs
      if stage["runs"]
        stage["runs"].each do |configuration, run|
          stage["runs"][configuration] = process_run(stage, run)
        end
      end

      # Delete unnecessary data
      %w{job number upstreams downstreams}.each { |key| stage.delete(key) }

      if stage["parameters"]
        # Sort the parameters
        stage["parameters"] = Helpers.reorder_fields(stage["parameters"])
      end

      stage["retries"] = stage["retries"].map { |r| r.is_a?(Hash) ? File.basename(r["url"]).to_i : r } if stage["retries"]
      stage["retries"] = stage["retries"].sort.reverse if stage["retries"]
      stage["retryOf"] = stage["retryOf"].sort.reverse if stage["retryOf"]

      if stage["runs"]
        failures = stage["runs"].select { |c,run| failed?(run) }
        if failures.any?
          failures = failures.group_by do |c,run|
            "#{(run["failureCategory"] || "unknown")} - #{(run["failureCause"] || "unknown")}"
          end
          failures.each do |cause, causedFailures|
            configurations = causedFailures.map { |configuration,run| configuration }
            failures[cause] = categorize_run_types(configurations, stage["runs"].keys).join(",")
          end
          stage["failures"] = failures
        else
          stage.delete("failures")
        end

        # Reorder runs by failure first, then by configuration name
        stage["runs"] = Hash[stage["runs"].sort_by { |configuration,run| "#{failed?(run) ? 0 : 1}-#{configuration}" }]
      end

      # Reorder fields for easier reading of YAML
      stage = Helpers.reorder_fields(stage, %w{result failures timestamp duration url}, "runs")

      stage
    end

    #
    # Runs
    #

    def fetch_runs(stage)
      runs = {}
      jenkins_pipeline.runs(stage).each do |run|
        job, build_number, configuration = jenkins_pipeline.parse_run_url(run["url"])
        raise "Run #{configuration} showed up twice in #{stage["url"]}!" if runs.has_key?(configuration)
        runs[configuration] = process_run(stage, run)
      end
      runs
    end

    def process_run(stage, run)
      timestamp = Time.parse(run["timestamp"]).utc
      run["timestamp"] = timestamp.to_s

      # Calculate delay
      delay = timestamp - Time.parse(stage["timestamp"])
      run["delay"] = delay

      # convert omnibus_timing -> omnibusTiming
      if timing = run.delete("omnibus_timing")
        run["omnibusTiming"] = timing
      end

      # Fix up failure cause from older versions
      if Hash === run["failureCause"]
        failure_cause = run["failureCause"]

        run["failedIn"] ||= {}
        run["failedIn"]["omnibus"] ||= failure_cause.delete("lastOmnibusStep") if failure_cause["lastOmnibusStep"]
        run["failedIn"]["jenkins"] ||= failure_cause.delete("jenkinsBuildStep") if failure_cause["jenkinsBuildStep"]
        run["failedIn"].merge!(failure_cause.delete("tests")) if failure_cause["tests"]
        failure_cause.delete("lastOmnibusLine") # just don't need this anymore; logExcerpts has it
        if failure_cause["suspiciousBlocks"]
          run["logExcerpts"] ||= {}
          run["logExcerpts"]["consoleText"] ||= failure_cause.delete("suspiciousBlocks")
        end

        run["failureCategory"] ||= failure_cause.delete("category")
        cause = failure_cause.delete("cause")
        unless failure_cause.empty?
          raise "failureCause for #{run["url"]} still has keys #{failure_cause.keys}! Cannot convert."
        end
        run["failureCause"] = cause
      end

      #
      # If it succeeded, it didn't fail :)
      #
      if SummaryCache.succeeded?(run)
        run.delete("failureCategory")
        run.delete("failureCause")
        run.delete("failedIn")
      end

      # Clean up empty fields
      run.delete("delay") if run["delay"] == 0.0
      %w{configuration job number artifacts}.each { |key| run.delete(key) }

      # Reorder run data for nicer printing
      run = Helpers.reorder_fields(run, %w{result failureCause failureCategory timestamp duration delay builtOn url})

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
      return filename if run["cachedThisTime"]

      if !File.exist?(filename) || force || in_progress?(run) || run["changedThisTime"]
        if build["missingFromJenkins"]
          Cli.logger.info("Not caching #{filename} because it's gone from Jenkins.")
        else
          console_text = fetch_console_text(run)
        end
        return nil if console_text.nil?
        unless File.exist?(filename) && console_text == IO.binread(filename)
          Cli.logger.info "Writing console text #{filename} ..."
          FileUtils.mkdir_p(File.dirname(filename))
          IO.binwrite(filename, console_text)
          run["changedThisTime"] = true
          run["cachedThisTime"] = true
        end
      end
      filename
    end

    def fetch_console_text(run)
      path = URI(File.join(run["url"], "consoleText")).path
      Cli.logger.info "GET #{path}"
      jenkins_pipeline.client.api_get_request(path, nil, nil, true).body
    end

    def console_text_filename(build, run)
      job, build_number, configuration = jenkins_pipeline.parse_run_url(run["url"])
      configuration.gsub!(/[^A-Za-z0-9\-]/, "_")
      File.join(build_directory(build), "#{job}-#{configuration}-#{build_number}.log")
    end

    #
    # Cache
    #
    def job_path
      File.join(path, jenkins_pipeline.job)
    end

    def build_directory(build=nil)
      if build["stages"]
        stage = build["stages"][jenkins_pipeline.job]
      else
        # we can be passed a remote or local build. this is a remote build.
        stage = build
      end
      File.join(job_path, "#{Time.parse(stage["timestamp"]).utc.strftime("%Y%m%d")}-#{File.basename(stage["url"])}")
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
          run.delete("cachedThisTime")
        end
      end

      # Write it out!
      filename = build_filename(build)
      desired_output = Psych.dump(build)
      unless File.exist?(filename) && IO.read(filename) == desired_output
        Cli.logger.info "Writing #{filename} ..."
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
end
