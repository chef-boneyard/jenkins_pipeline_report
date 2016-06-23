module JenkinsPipelineReport
  module Report
    class FailureExtractor
      attr_reader :stage
      attr_reader :report

      def initialize(stage, report)
        @stage = stage
        @report = report
      end

      def extract
        extract_failed_in
        extract_cause
      end

      private

      def extract_cause
        return if stage.build.result == "SUCCESS"

        # If it failed but its result was something other than failure (such as
        # "aborted"), use that as the cause. For example, "aborted"
        if stage.build.result != "FAILURE"
          report["failure_category"] = stage.build.result.downcase
          report["failure_cause"] = stage.build.result.downcase
          return
        end

        # P1 failures (test failures)
        if report["failed_in"]
          failed_tests = {}
          report["failed_in"].each do |type,tests|
            next if %w{omnibus jenkins}.include?(type) # not a test
            failed_tests[type] = tests.uniq
          end
          if failed_tests.any?
            report["failure_category"] = "code"
            report["failure_cause"] = failed_tests.map do |test_type, tests|
              if tests.size <= 3
                "#{test_type}[#{tests.join(",")}]"
              else
                test_type
              end
            end.join(",")
            return
          end
        end

        # P3 failure cases
        stage.console_text_lines.each do |line|
          case line
          when /Failed to connect to (.+) port (\d+): Timed out/i,
               /Failed connect to (.+):(\d+); (Operation|Connection) (timed out|now in progress)/i
            category, cause = "network", "network timeout #{$1}:#{$2}"
          end
          if cause
            report["failure_category"] = category
            report["failure_cause"] = cause
            return
          end
        end

        # P2 failure causes
        stage.console_text_lines.each do |line|
          case line
          when /Slave went offline during the build/
            category, cause = "network", "worker disconnected"

          when /The --deployment flag requires a .*\/([^\/]+\/Gemfile.lock)/
            category, cause = "code", "missing #{$1}"

          when /(EACCES)/,
               /java.io.FileNotFoundException.*(Permission denied)/
            category, cause = "machine", "disk space (#{$1})"

          when /Cannot delete workspace:.*The process cannot access the file because it is being used by another process./i
            category, cause = "machine", "zombie jenkins"

          when /ECONNRESET/
            if excerpt =~ /ECONNRESET.*(https?:\/\/\S+)/
              url = $1
              hostname = URI(url).hostname
            end
            category, cause = "network", "network reset#{hostname ? " #{hostname}" : ""}"

          when /jenkinsci.*Connection timed out/i
            category, cause = "network", "network timeout jenkins"

          when /IOException.*: Failed to extract/i
            category, cause = "network", "jenkins copy"

          when /Unable to create .*index.lock.*File exists/mi
            category, cause = "machine", "git index.lock"

          when /Dumping stack trace to\s+(\S+).stackdump/mi
            category, cause = "machine", "segfault #{$1}"

          when /Finder got an error: Application isn.*t running/i
            category, cause = "machine", "mac not logged in"

          when /Gemfile\.lock is corrupt/
            category, cause = "code", "corrupt Gemfile.lock"

          when /An error occurred while installing (\S+) \(([^\)]+)\)/i
            category, cause = "code", "gem install #{$1} -v #{$2}"

          when /rubygems\.org.*Checksum of (\S+) does not match the checksum provided by server/mi
            category, cause = "network", "rubygems #{$1} checksum"

          when /Could not find (\S+) in any of the sources/i
            category, cause = "code", "yanked gem #{$1}"

          end

          if cause
            report["failure_category"] = category
            report["failure_cause"] = cause
            return
          end
        end

        # Mark failure_cause as the failed omnibus step if all else fails
        if report["failed_in"] && report["failed_in"]["omnibus"]
          report["failure_category"] ||= "code"
          report["failure_cause"] ||= report["failed_in"]["omnibus"]
        end
      end

      def extract_failed_in
        # Don't bother if the run failed
        return unless stage.build.result == "FAILED"

        failed_in = report["failed_in"] || {}

        stage.console_text_lines.each do |line|

          case line
          # chef verify failures
          when /^\s*Verification of component '(.+)' failed.\s*$/i
            failed_in ||= {}
            failed_in["chef verify"] ||= []
            failed_in["chef verify"] |= [ $1 ]
            failed_in["chef verify"].sort!

          # jenkins failure
          when /^\s*Build step '(.+)' (marked build as|changed build result to) failure\s*$/i
            failed_in["jenkins"] ||= $1

          end

        end

        if report["steps"] && report["steps"]["omnibus"]
          failed_in["omnibus"] = last_omnibus_step(report["steps"]["omnibus"])
        end

        report["failed_in"] = failed_in
      end
    end
  end
end
