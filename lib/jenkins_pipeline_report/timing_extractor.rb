require_relative "helpers"

module JenkinsPipelineReport
  class TimingExtractor
    def self.extract(configuration, run, force: false)
      return if run["stepTiming"] && run["acceptanceTiming"] && !run["changedThisTime"] && !force
      return unless run["logExcerpts"] && run["logExcerpts"]["consoleText"]

      extract_acceptance_timing(configuration, run, force: force)
      extract_step_timing(run, force: force)
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

    def self.extract_step_timing(run, force: false)
      # step timing
      current_start_time = run["timestamp"]
      current_step = "setup"
      last_step_time = current_start_time
      step_timing = {}
      run["logExcerpts"]["consoleText"].each do |log_index, excerpt|
        excerpt.each_line do |line|
          case line
          # [Builder: chef] I | 2016-05-11T20:29:35+00:00 | ...
          #                 I | 2016-05-11T20:29:35+00:00 | ...
          when /^\s*(\[(.+)\])? [A-Z] \| (\d+-\d+-\d+T\d+:\d+:\d+[+-]\d+:\d+) \|/
            step = $2 || current_step
            time = $3
          # CHEF-ACCEPTANCE::PROVISION[2016-06-10 23:54:43 +0000]
          when /^(CHEF-ACCEPTANCE)::\S*\[(\d+-\d+-\d+ \d+:\d+:\d+ [+-]\d+)\]/
            step = $1
            time = $2
          else
            next
          end

          unless step == current_step
            if current_step == "setup"
              # We have encountered our first omnibus step. Assign the time from
              # the start of the build till now to "setup".
              step_timing[current_step] ||= 0
              step_timing[current_step] += Time.parse(time).to_f - Time.parse(run["timestamp"]).to_f
              current_start_time = time
            else
              # We have encountered a new omnibus step. The old omnibus step ends
              # *before* this one, and any time in between its last timestamp and
              # the new step's start timestamp is counted against the *new* step.
              # Therefore, in this:
              # [A] W | 2016-12-01 01:10:00 | ...
              # [A] W | 2016-12-01 01:20:00 | ...
              # [B] W | 2016-12-01 01:30:00 | ...
              # [B] W | 2016-12-01 01:40:00 | ...
              # A takes 10 minutes, and B takes 20 minutes.
              step_timing[current_step] ||= 0
              step_timing[current_step] += Time.parse(last_step_time).to_f - Time.parse(current_start_time).to_f
              current_start_time = last_step_time
            end
            current_step = step
          end
          last_step_time = time
        end
      end

      step_timing[current_step] ||= 0
      step_timing[current_step] += Time.parse(last_step_time).to_f - Time.parse(current_start_time).to_f

      # cleanup takes the entire rest of the duration, automatically.
      step_timing["cleanup"] = run["duration"] - (Time.parse(last_step_time).to_f - Time.parse(run["timestamp"]).to_f)

      run.delete("omnibusTiming")
      run["stepTiming"] = step_timing
    end
  end
end
