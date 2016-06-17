require_relative "summary_cache"
require_relative "helpers"

module JenkinsPipelineReport
  class FailureExtractor
    def self.extract(run, force: false)
      extract_failed_in(run, force: force)
      extract_cause(run, force: force)
    end

    private

    def self.extract_cause(run, force: true)
      return unless SummaryCache.failed?(run) && (!run["failureCategory"] || !run["failureCause"] || force || run["changedThisTime"])

      unless run["logExcerpts"] && run["logExcerpts"]["consoleText"]
        run["failureCategory"] ||= "system"
        run["failure"] ||= "no logs"
      end

      # If it failed but its result was something other than failure (such as
      # "aborted"), use that as the cause. For example, "aborted"
      if run["result"].downcase != "failure"
        run["failureCategory"] = run["result"].downcase
        run["failureCause"] = run["result"].downcase
        return
      end

      # P1 failures (test failures)
      if run["failedIn"]
        failed_tests = {}
        run["failedIn"].each do |type,tests|
          next if %w{omnibus jenkins}.include?(type) # not a test
          failed_tests[type] = tests.uniq
        end
        if failed_tests.any?
          run["failureCategory"] = "code"
          run["failureCause"] = failed_tests.map do |test_type, tests|
            if tests.size <= 3
              "#{test_type}[#{tests.join(",")}]"
            else
              test_type
            end
          end.join(",")
          return
        end
      end

      if run["logExcerpts"] && run["logExcerpts"]["consoleText"]
        # P2 failure causes
        run["logExcerpts"]["consoleText"].each do |line_number, excerpt|
          case excerpt
          when /Failed to connect to (.+) port (\d+): Timed out/i,
               /Failed connect to (.+):(\d+); (Operation|Connection) (timed out|now in progress)/i
            category, cause = "network", "network timeout #{$1}:#{$2}"
          end
          if cause
            run["failureCategory"] = category
            run["failureCause"] = cause
            return
          end
        end

        # P3 failure causes
        run["logExcerpts"]["consoleText"].each do |line_number, excerpt|
          case excerpt
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
            run["failureCategory"] = category
            run["failureCause"] = cause
            return
          end
        end
      end

      # Mark failureCause as the failed omnibus step if all else fails
      if run["failedIn"] && run["failedIn"]["omnibus"]
        run["failureCategory"] ||= "code"
        run["failureCause"] ||= run["failedIn"]["omnibus"]
      end
    end

    def self.extract_failed_in(run, force: false)
      # Don't bother if the run failed
      return unless SummaryCache.failed?(run)
      # Only reprocess if forced to
      return unless !run["failedIn"] || force || run["changedThisTime"]
      # Can't work on it if there are no logs.
      return unless run["logExcerpts"] && run["logExcerpts"]["consoleText"]

      failed_in = {}

      run["logExcerpts"]["consoleText"].each do |log_index, excerpt|
        # chef-acceptance failures
        Helpers.extract_chef_acceptance_results(excerpt).each do |results|
          failures = results.select { |result| result["error"] == "Y" && result["command"] != "Total" }
          if failures.any?
            chef_acceptance_failures ||=  {}
            failed_in["chef-acceptance"] ||= []
            failures.each do |failure|
              failed_in["chef-acceptance"] |= [ "#{failure["suite"]} (#{failure["command"]})" ]
            end
          end
        end

        # chef verify failures
        excerpt.scan(/^\s*Verification of component '(.+)' failed.\s*$/i) do
          failed_in ||= {}
          failed_in["chef verify"] ||= []
          failed_in["chef verify"] |= [ $1 ]
          failed_in["chef verify"].sort!
        end

        # jenkins failure
        if excerpt =~ /^\s*Build step '(.+)' (marked build as|changed build result to) failure\s*$/i
          failed_in["jenkins"] ||= $1
        end
      end

      # Find the last omnibus line in the last excerpt
      run["logExcerpts"]["consoleText"].reverse_each do |log_index, excerpt|
        last_omnibus_line = excerpt.scan(/^\s*\[([^\]]+)\] . \| /).last
        if last_omnibus_line
          # If it's timing information, we did *not* fail in omnibus.
          if last_omnibus_line =~ /:\s+(\d+(\.\d+)?)s$/
            failed_in.delete("omnibus")
          else
            failed_in["omnibus"] = $1
          end
          break
        end
      end

      run["failedIn"] = Helpers.reorder_fields(failed_in, [], "omnibus")
    end
  end
end
