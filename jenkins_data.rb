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

  def refresh
    builds = jenkins.builds
    builds.each do |stages|
      # Transform to a hash for easy reading
      stages = stages.each_with_object({}) { |b, hash| hash[b["job"]] = b }
      first_stage = stages.values.first
      last_stage = stages.values.last

      filename = File.join(path, first_stage["job"], "#{stages.values.first["number"]}.yaml")
      FileUtils.mkdir_p(File.dirname(filename))

      build = {
        "version" => last_stage["parameters"]["OMNIBUS_BUILD_VERSION"],
        "result" => last_stage["result"],
        "timestamp" => first_stage["timestamp"],
        "duration" => stages.values.inject(0.0) { |sum,stage| sum += stage["duration"] },
        "git_commit" => last_stage["parameters"]["GIT_COMMIT"],
        "stages" => stages,
      }

      stages.each_with_index do |(job, stage), index|
        stage.delete("parameters") if index > 0
        stage.delete("job")
        stage.delete("number")

        # Put these keys at the front of the hash for easier reading
        reordered_stage = {}
        %w{result timestamp duration url}.each do |k,hash|
          reordered_stage[k] = stage[k] if stage.has_key?(k)
        end
        reordered_stage.merge!(stage)

        stages[job] = reordered_stage
      end
      first_stage = stages.values.first
      last_stage = stages.values.last

      # Skip the expensive run retrieval if our data changes nothing
      if File.exist?(filename)
        existing_build = YAML.load(IO.read(filename))
        build = existing_build.merge(build)
        build["stages"] = existing_build["stages"].merge(build["stages"])
        build["stages"].each do |job, b|
          build["stages"][job] = existing_build["stages"][job].merge(b) if existing_build["stages"].has_key?(job)
        end
      end

      if true || build != existing_build || last_stage["result"].nil?
        # Grab all run data
        build["stages"].each do |job, stage|
          runs = jenkins.runs(stage)
          runs = runs.each_with_object({}) do |run,hash|
            # Calculate delay
            delay = Time.parse(run["timestamp"]) - Time.parse(stage["timestamp"])
            run["delay"] = delay

            configuration = run["configuration"]

            raise "Run #{configuration} showed up twice in #{b["url"]}!" if hash.has_key?(configuration)
            run = stage["runs"][configuration].merge(run) if stage["runs"] && stage["runs"][configuration]

            # Remove these unnecessary keys
            run.delete("configuration")
            run.delete("job")
            run.delete("number")
            run.delete("artifacts")
            run.delete("delay") if run["delay"] == 0.0

            # Put these keys at the front of the hash for easier reading
            reordered_run = {}
            %w{result timestamp duration delay builtOn url}.each do |k,hash|
              reordered_run[k] = run[k] if run.has_key?(k)
            end
            reordered_run.merge!(run)

            hash[configuration] = reordered_run
          end
          stage["runs"] = runs
        end
      end

      build["stages"].each do |job, stage|
        stage["runs"].each do |configuration, run|
          if run["result"] == "SUCCESS"
            run["omnibus_builders"] ||= process_omnibus_times(run)
          end
        end
      end

      # Write it out!
      puts "Writing #{filename} ..."
      IO.write(filename, YAML.dump(build))
    end
    builds
  end

  def load
    job_path = File.join(path, jenkins.job)
    raise "#{job_path} does not exist! Cannot load local builds." unless File.directory?(job_path)

    builds = Dir.entries(job_path).map do |entry|
      next unless File.extname(entry) == ".yaml"
      filename = File.join(job_path, entry)
      YAML.load(IO.read(filename))
    end
    builds.sort_by { |build| build["timestamp"] }.reverse
  end

  private

  def process_omnibus_times(run)
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
end
