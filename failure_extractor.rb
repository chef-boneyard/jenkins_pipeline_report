require_relative "jenkins_data"
require_relative "jenkins_helpers"

class FailureExtractor
  def self.extract(build, run, console_text)
    FailureExtractor.new(console_text).extract(build, run)
  end

  def self.deduce_cause(run)
    begin
      cause = run["failureCause"]
      if JenkinsData.failed?(run) && run["result"].downcase != "failure"
        cause ||= begin
          run["failureCause"] = {}
        end
        cause["cause"] = run["result"].downcase
        cause["detailedCause"] = cause["cause"]
        return
      end

      if cause
        # If we can't think of anything more specific, the cause will be the last omnibus step
        if cause["lastOmnibusStep"]
          cause["cause"] = "omnibus"
          cause["detailedCause"] = "omnibus #{cause["lastOmnibusStep"]}"
        end

        if cause["suspiciousBlocks"]
          cause["suspiciousBlocks"].each do |line_number, suspicious_block|
            if suspicious_block =~ /^\s*Verification of component '(.+)' failed.\s*$/i
              cause["tests"] ||= {}
              cause["tests"]["chef verify"] ||= []
              cause["tests"]["chef verify"] |= [ $1 ]
            end

            if suspicious_block =~ /^\s*Build step '(.+)' (marked build as|changed build result to) failure\s*$/i
              cause["jenkinsBuildStep"] ||= $1
            end

            case suspicious_block
            when /The --deployment flag requires a .*\/([^\/]+\/Gemfile.lock)/
              cause["cause"] = "missing Gemfile.lock"
              cause["detailedCause"] = "missing #{$1}"

            when /(EACCES)/,
                 /java.io.FileNotFoundException.*(Permission denied)/
              cause["cause"] = "disk space"
              cause["detailedCause"] = "disk space (#{$1})"

            when /Cannot delete workspace:.*The process cannot access the file because it is being used by another process./i
              cause["cause"] = "zombie jenkins"
              cause["detailedCause"] = "zombie jenkins"

            when /ECONNRESET/
              if suspicious_block =~ /ECONNRESET.*(https?:\/\/\S+)/
                url = $1
                hostname = URI(url).hostname
              end
              cause["cause"] = "network reset"
              cause["detailedCause"] = "network reset#{hostname ? " #{hostname}" : ""}"

            when /jenkinsci.*Connection timed out/i
              cause["cause"] = "network timeout"
              cause["detailedCause"] = "network timeout jenkins"

            when /IOException.*: Failed to extract/i
              cause["cause"] = "jenkins copy"
              cause["detailedCause"] = "jenkins copy"

            when /Failed to connect to (.+) port (\d+): Timed out/i,
                 /Failed connect to (.+):(\d+); (Operation|Connection) (timed out|now in progress)/i
              cause["cause"] = "network timeout"
              cause["detailedCause"] = "network timeout #{$1}:#{$2}"
              return

            when /Unable to create .*index.lock.*File exists/mi
              cause["cause"] = "git index.lock"
              cause["detailedCause"] = "git index.lock"

            when /Dumping stack trace to\s+(\S+).stackdump/mi
              cause["cause"] = "segfault"
              cause["detailedCause"] = "segfault #{$1}"

            when /Finder got an error: Application isn.*t running/i
              cause["cause"] = "mac not logged in"
              cause["detailedCause"] = "mac not logged in"

            when /Gemfile\.lock is corrupt/
              cause["cause"] = "corrupt Gemfile.lock"
              cause["detailedCause"] = cause["cause"]

            when /An error occurred while installing (\S+) \(([^\)]+)\)/i
              cause["cause"] = "gem install"
              cause["detailedCause"] = "gem install #{$1} -v #{$2}"

            when /rubygems\.org.*Checksum of (\S+) does not match the checksum provided by server/mi
              cause["cause"] = "rubygems checksum"
              cause["detailedCause"] = "rubygems #{$1} checksum"

            when /Could not find (\S+) in any of the sources/i
              cause["cause"] = "yanked gem"
              cause["detailedCause"] = "yanked gem #{$1}"

            end
          end
        end

        if cause["tests"]
          cause["tests"].each do |type,tests|
            tests.uniq!
          end
          cause["cause"] = "#{cause["tests"].keys.join(",")}"
          cause["detailedCause"] = cause["tests"].map do |test_type, t|
            if t.size <= 3
              "#{test_type}[#{t.join(",")}]"
            else
              test_type
            end
          end.join(",")
        end
      end
    ensure
      run["failureCause"] = order_fields(cause) if cause
    end
  end

  def extract(build, run)
    cause = {}
    extract_suspicious_blocks(run, cause)
    extract_other_stuff(run, cause)
    run["failureCause"] = self.class.order_fields(cause)
  end

  private

  def self.order_fields(cause)
    JenkinsHelpers.reorder_fields(cause,
      %w{cause detailedCause shellCommand jenkinsBuildStep})
  end

  attr_reader :lines

  def initialize(console_text)
    @lines = console_text.lines
  end

  def extract_other_stuff(run, cause)
    # Step backwards
    index = lines.size - 1
    while index >= 0
      line = lines[index]
      # Build step 'Invoke XShell command' marked build as failure
      case line
      when /^CHEF-ACCEPTANCE::\[[^\]]+\]\s+\|(.+)\|\s*$/
        index, results = JenkinsHelpers.extract_chef_acceptance_result(lines, index)
        failures = results.select { |result| result["error"] == "Y" && result["command"] != "Total" }
        if failures.any?
          cause["tests"] ||=  {}
          cause["tests"]["chef-acceptance"] ||= []
          failures.each do |failure|
            cause["tests"]["chef-acceptance"] |= [ "#{failure["suite"]} (#{failure["command"]})" ]
          end
        end

        #                         [Licensing] W | License file '/var/cache/omnibus/src/pry/LICENSE' does not exist for software 'pry'.
        when /^\s*\[([^\]]+)\] . \| /
          cause["lastOmnibusStep"] ||= $1
          cause["lastOmnibusLine"] ||= line.strip
      end

      index -= 1
    end
  end

  def extract_suspicious_blocks(run, cause, context: 2)
    current_block = nil
    suspicious_blocks = {}
    lines.each_with_index do |line,index|
      range = nil

      case line
      when /The --deployment flag requires a/,
           /EACCES/,
           /\bERROR\b/,
           /\bFATAL\b/i,
           /Errno::ECONNRESET/,
           /Permission denied/i,
           /Connection timed out/i,
           /Failed to complete (.*) action:/i,
           #  java stacktrace
           # 	at com.michelin.cio.hudson.plugins.copytoslave.MyFilePath.copyRecursiveTo(MyFilePath.java:147)
           /^\s*at ([a-z_]\w*\.)+[A-Z_]\w*\.[a-z_]\w*\([^\)]*\)\s*$/,
           # ruby stacktrace
           #   /home/jenkins/workspace/chefdk-build/architecture/x86_64/platform/debian-6/project/chefdk/role/builder/omnibus/vendor/bundle/ruby/2.1.0/bundler/gems/omnibus-7c98e2bbceb7/lib/omnibus/thread_pool.rb:61:in `block (2 levels) in initialize'
           /^\s*(\S+):(\d+):in `([^']*)'/,
           /^\s*Build step '(.+)' (marked build as|changed build result to) failure\s*$/i,
           /^\s*Verification of component '(.+)' failed.\s*$/i

        range = index..index

      # The following shell command exited with status 128:
      #
      #     $ git ls-remote "http://git.savannah.gnu.org/r/config.git" "master*"
      #
      # Output:
      #
      #     (nothing)
      #
      # Error:
      #
      #     fatal: unable to access 'http://git.savannah.gnu.org/r/config.git/': Failed connect to git.savannah.gnu.org:80; Operation now in progress
      #
      when /^\s*The following shell command exited with status \S+:\s*$/i
        # The following shell command exited with status 128:
        #
        end_index = index

        while lines[end_index].chomp != ""
          end_index += 1
        end
        end_index += 1

        #     $ git ls-remote "http://git.savannah.gnu.org/r/config.git" "master*"
        #
        while lines[end_index].chomp != ""
          end_index += 1
        end
        end_index += 1

        # Output:
        #
        while lines[end_index].chomp != ""
          end_index += 1
        end
        end_index += 1

        #     (nothing)
        #
        while lines[end_index].chomp != ""
          end_index += 1
        end
        end_index += 1

        # Error:
        #
        while lines[end_index].chomp != ""
          end_index += 1
        end
        end_index += 1

        #     fatal: unable to access 'http://git.savannah.gnu.org/r/config.git/': Failed connect to git.savannah.gnu.org:80; Operation now in progress
        #
        while lines[end_index].chomp != ""
          end_index += 1
        end
        end_index += 1

        range = index..end_index

      end

      if range
        # Add context
        range = (range.min-context)..(range.max+context)
        # If we're part of the range-being-emitted, extend the range
        if current_block && range.min <= current_block.max+1
          start_emit = current_block.max+1
          current_block = current_block.min..range.max if range.max > current_block.max
        else
          start_emit = range.min
          current_block = range
        end
        block = suspicious_blocks[current_block.min] ||= ""
        start_emit.upto(current_block.max) do |i|
          block << fix_unsightly_characters(lines[i])
        end
      end
    end
    cause["suspiciousBlocks"] = suspicious_blocks unless suspicious_blocks.empty?
  end

  def fix_unsightly_characters(line)
    line = line.gsub("\r", "")
    line.gsub("\t", "  ")
  end
end
