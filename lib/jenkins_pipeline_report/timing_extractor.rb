require_relative "helpers"

module JenkinsPipelineReport
  class TimingExtractor
    def self.extract(configuration, run, console_text)
      # Look for timing information
      omnibus_timing = {}
      acceptance_timing = []
      lines = console_text.lines
      index = lines.size-1
      while index >= 0
        line = lines[index]
        if line =~ /^CHEF-ACCEPTANCE::\[[^\]]+\]\s+\|(.+)\|\s*$/
          index, results = Helpers.extract_chef_acceptance_result(lines, index)
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
  end
end
