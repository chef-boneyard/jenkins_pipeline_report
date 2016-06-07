require_relative "helpers"

module JenkinsPipelineReport
  class TimingExtractor
    def self.extract(configuration, run, force: false)
      return if run["omnibusTiming"] && run["acceptanceTiming"] && !force
      return unless run["logExcerpts"] && run["logExcerpts"]["consoleText"]

      extract_acceptance_timing(configuration, run, force: force)
      extract_omnibus_timing(run, force: force)
    end

    def self.extract_acceptance_timing(configuration, run, force: false)
      # chef-acceptance timing
      acceptance_timing = []
      run["logExcerpts"]["consoleText"].each do |log_index, excerpt|
        Helpers.extract_chef_acceptance_results(excerpt).each do |results|
          acceptance_run = {}
          results.each do |result|
            acceptance_run[result["suite"]] ||= {}
            acceptance_run[result["suite"]][result["command"]] = result["duration"]
          end
          acceptance_timing << acceptance_run
        end
      end
      run["acceptanceTiming"] = acceptance_timing if configuration == "acceptance" || acceptance_timing.any?
    end

    def self.extract_omnibus_timing(run, force: false)
      # omnibus timing
      current_start_time = nil
      current_omnibus_step = nil
      last_omnibus_time = nil
      omnibus_timing = {}
      run["logExcerpts"]["consoleText"].each do |log_index, excerpt|
        # [Builder: chef] I | 2016-05-11T20:29:35+00:00 | ...
        excerpt.scan(/^(\s*(\[(.+)\])? [A-Z] \| ([0-9\-T\+-:]+) \|.*)/) do
          line = $1
          step = $3 || current_omnibus_step
          time = $4
          unless step == current_omnibus_step
            if current_omnibus_step
              omnibus_timing[current_omnibus_step] ||= 0
              omnibus_timing[current_omnibus_step] += Time.parse(last_omnibus_time).to_i - Time.parse(current_start_time).to_i
            end
            current_omnibus_step = step
            current_start_time = time
          end
          last_omnibus_time = time
        end
      end
      if current_omnibus_step
        omnibus_timing[current_omnibus_step] ||= 0
        omnibus_timing[current_omnibus_step] += Time.parse(last_omnibus_time).to_i - Time.parse(current_start_time).to_i
      end

      run["omnibusTiming"] = omnibus_timing
    end
  end
end
