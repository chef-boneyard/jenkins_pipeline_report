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

      stages.each_with_index do |(id, stage), index|
        # Put these keys at the front of the hash for easier reading
        stage = %w{result timestamp duration url}.each_with_object({}) { |k,hash| hash[k] = nil }.
                merge(stage)
        stage.delete("parameters") if index > 0
        stage.delete("job")
        stage.delete("number")
        stages[id] = stage
      end
      first_stage = stages.values.first
      last_stage = stages.values.last

      # Skip the expensive run retrieval if our data changes nothing
      if File.exist?(filename)
        existing_build = YAML.load(IO.read(filename))
        build = existing_build.merge(build)
        build["stages"] = existing_build["stages"].merge(build["stages"])
        build["stages"].each do |id, b|
          build["stages"][id] = existing_build["stages"][id].merge(b) if existing_build["stages"].has_key?(id)
        end
        if build == existing_build && !last_stage["result"].nil?
          puts "Skipping #{filename} (unchanged) ..."
          next
        end
      end

      # Grab all run data
      build["stages"].each do |id, stage|
        runs = jenkins.runs(stage)
        runs = runs.each_with_object({}) do |run,hash|
          # Put these keys at the front of the hash for easier reading
          run = %w{result timestamp duration builtOn url}.each_with_object({}) { |k,hash| hash[k] = nil }.
                merge(run)

          # Remove these unnecessary keys
          configuration = run.delete("configuration")
          run.delete("job")
          run.delete("number")
          run.delete("artifacts")

          raise "Run #{run["configuration"]} showed up twice in #{b["url"]}!" if hash.has_key?(run["configuration"])
          hash[configuration] = run
        end
        stage["runs"] = runs
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
end
