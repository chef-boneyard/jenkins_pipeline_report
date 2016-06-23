require_relative "timing_extractor/step"

module JenkinsPipelineReport
  module Report
    class TimingExtractor
      attr_reader :stage
      attr_reader :report
      attr_reader :steps

      def initialize(stage, report)
        @stage = stage
        @report = report
      end

      def extract
        extract_step_timing
      end

      private

      attr_reader :last_step
      attr_reader :current_index

      def update_step(*path, time:)
        last_step.update(time: time) if last_step && last_step.open?
        @last_step = steps.update(*path, time: time, index: current_index)
      end

      def extract_step_timing
        @current_index = 0
        @steps = Step.new("run", start_time: stage.build.timestamp, start_index: current_index)

        # Extract the first and last line for each
        stage.console_text_lines.each_with_index do |line, i|
          @current_index = i

          case line
          # [Builder: chef] I | 2016-05-11T20:29:35+00:00 | ...
          #                 I | 2016-05-11T20:29:35+00:00 | ...
          when /^\s*(\[(.+)\])? [A-Z] \| (\d+-\d+-\d+T\d+:\d+:\d+[+-]\d+:\d+) \|/
            found_omnibus_line($2, $3)

          # CHEF-ACCEPTANCE::PROVISION[2016-06-10 23:54:43 +0000]
          when /^(\S+)::(\S*)\s*\[(\d+-\d+-\d+ \d+:\d+:\d+ [+-]\d+)\]/
            # MODULE::[ACTION]
            time = $3
            path = [ $1 ]
            path << $2 unless $2.empty?
            # MODULE::ACTION -> CHEF-ACCEPTANCE::MODULE::ACTION
            path.unshift("CHEF-ACCEPTANCE") unless path[0] == "CHEF-ACCEPTANCE"
            update_step(*path, time: time)

          when /^Starting Pedant Run: (.+)/
            time = $1
            steps.close("pedant")
            update_step("pedant", time: time)

          when /^Finished in (\S+) minutes (\S+) seconds \(files took \S+ seconds to load\)/
            duration = $1.to_f*60+$2.to_f
            pedant = steps.get("pedant")
            if pedant
              time = (pedant.start_time + duration).to_s
              update_step("pedant", time: time)
              steps.close("pedant")
            end

          when /^\[(\d+-\d+-\d+T\d+:\d+:\d+[+-]\d+:\d+)\] INFO: \*\*\* Chef \S+ \*\*\*$/
            time = $1
            steps.close("chef-client")
            update_step("chef-client", time: time)

          when /^\[(\d+-\d+-\d+T\d+:\d+:\d+[+-]\d+:\d+)\] INFO: Run List expands to \[(.+)\]/
            time = $1
            run_list = $2
            chef_client = update_step("chef-client", time: time)
            chef_client.display = "chef-client #{run_list}"

          when /^\[(\d+-\d+-\d+T\d+:\d+:\d+[+-]\d+:\d+)\] INFO: Chef Run complete in \S+ seconds/
            time = $1
            update_step("chef-client", time: time)
            steps.close("chef-client")

          end
        end

        if stage.build.duration
          steps.update(time: steps.start_time + stage.build.duration, index: current_index)
        end
        steps.close

        # Print the result in nice simple format
        step_timing = steps.step_timing
        # If step timing is a duration, it's going to be the same as the full
        # duration. Ignore it.
        unless step_timing.is_a?(Numeric)
          report["steps"] = step_timing
        end
      end

      def found_omnibus_line(description, time)
        path = [ "omnibus", nil ]
        path += description.split(": ") if description

        # If it's GitCache, move omnibus forward to the build stage
        omnibus = steps.get("omnibus")
        if omnibus
          if %w{GitCache Builder}.include?(path[2])
            path[1] = "build"
            # When a new GitCache or Builder starts, all other things in other categories stop
            if path[3] && !steps.get(*path)
              categories = steps.get(*path[0..1])
              if categories
                categories.open_children.each do |key, category|
                  if key == path[2]
                    category.close_all_except(path[3])
                  else
                    category.close_all
                  end
                end
              end
            end
          else
            path[1] = omnibus.open_children.keys.first
          end
        end
        path[1] ||= "fetch"
        # Stages are mutually exclusive
        if omnibus
          omnibus.close_all_except(path[1])
        end

        update_step(*path, time: time)
      end
    end
  end
end
