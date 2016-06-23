module JenkinsPipelineReport
  module Report
    class AcceptanceExtractor
      attr_reader :stage
      attr_reader :report

      def initialize(stage, report)
        @stage = stage
        @report = report
      end

      def parse_duration(duration)
        return nil unless duration
        seconds, minutes, hours = duration.split(":").reverse
        hours = hours ? hours.to_f : 0
        minutes = minutes ? minutes.to_f : 0
        seconds = seconds ? seconds.to_f : 0
        minutes += hours*60
        seconds += minutes*60
        seconds
      end

      def extract
        # chef-acceptance timing
        acceptance_timing = []
        failures = []
        chef_acceptance_results.each do |results|
          acceptance_run = {}
          results.each do |result|
            duration = parse_duration(result["duration"])
            acceptance_run[result["suite"]] ||= {}
            acceptance_run[result["suite"]][result["command"]] = BuildReport.format_duration(duration)
            if result["error"] == "Y" && result["command"] != "Total"
              failures << result
            end
          end
          acceptance_timing << acceptance_run
        end

        if acceptance_timing.any?
          report["chef_acceptance_timing"] = acceptance_timing
        end

        if failures.any?
          report["failed_in"] ||= {}
          report["failed_in"]["chef_acceptance"] = failures.map do |failure|
            "#{failure["suite"]}::#{failure["command"]}"
          end
        end
      end

      def chef_acceptance_results
        return enum_for(:chef_acceptance_results) unless block_given?

        # CHEF-ACCEPTANCE::[2016-05-13 20:19:04 +0000] chef-acceptance run succeeded
        # CHEF-ACCEPTANCE::[2016-05-13 20:19:04 +0000] | Suite   | Command   | Duration | Error |
        # CHEF-ACCEPTANCE::[2016-05-13 20:19:04 +0000] | trivial | provision | 00:01:21 | N     |
        # CHEF-ACCEPTANCE::[2016-05-13 20:19:04 +0000] | trivial | verify    | 00:00:15 | N     |
        # CHEF-ACCEPTANCE::[2016-05-13 20:19:04 +0000] | trivial | destroy   | 00:00:07 | N     |
        # CHEF-ACCEPTANCE::[2016-05-13 20:19:04 +0000] | trivial | Total     | 00:01:58 | N     |
        # CHEF-ACCEPTANCE::[2016-05-13 20:19:04 +0000] | Run     | Total     | 00:01:58 | N     |
        result = nil
        field_names = nil
        stage.console_text_lines.each do |line|
          if line =~ /^CHEF-ACCEPTANCE::\[[^\]]+\]\s+\|(.+)\|\s*$/
            row = $1.split("|").map { |f| f.strip }
            if field_names
              result << Hash[field_names.zip(row)]
            else
              # If the current_result exists, this is a new section. Add a result
              # and parse field names
              field_names = row.map { |name| name.downcase }
              result = []
            end
          else
            yield result if result && result.any?
            # We're not in a result block anymore, so clear out field names and result
            field_names = nil
            result = nil
          end
        end
        yield result if result
      end
    end
  end
end
