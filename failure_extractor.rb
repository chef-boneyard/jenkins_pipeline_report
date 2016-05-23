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

            when /Verification of component '(.+)' failed./
              cause["tests"] ||= {}
              cause["tests"]["chef verify"] ||= []
              cause["tests"]["chef verify"] << $1

            when /jenkinsci.*Connection timed out/i
              cause["cause"] = "network timeout"
              cause["detailedCause"] = "network timeout jenkins"

            when /IOException.*: Failed to extract/i
              cause["cause"] = "jenkins copy"
              cause["detailedCause"] = "jenkins copy"

            end
          end
        end

        if cause["tests"]
          cause["cause"] = "#{cause["tests"].keys.join(",")}"
          cause["detailedCause"] = cause["tests"].map do |test_type, t|
            if t.size <= 3
              "#{test_type}[#{t.join(",")}]"
            else
              test_type
            end
          end.join(",")
        end

        if cause["shellCommand"]
          case cause["shellCommand"]["stderr"]
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
          end

          case cause["shellCommand"]["stdout"]
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
      %w{cause detailedCause shellCommand stacktrace jenkinsBuildStep})
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
      when /^\s*Build step '(.+)' (marked build as|changed build result to) failure\s*$/i
        cause["jenkinsBuildStep"] ||= $1

      when /^\s*(\S+)(:\d+:in `.+')\s*$/
        index, stacktrace = extract_stacktrace(lines, index)
        if stacktrace.any?
          cause["stacktraces"] ||= []
          cause["stacktraces"] << stacktrace
        end

      # Kitchen stack trace
      #     D      ------Backtrace-------
      when /^\s*\S\s+-+Backtrace-+\s*$/
        stacktrace = extract_kitchen_stacktrace(lines, index+1)
        if stacktrace.any?
          cause["stacktraces"] ||= []
          cause["stacktraces"] << stacktrace
        end

      when /^The following shell command exited with status (-?\d+):\s/
        command = extract_shell_command(lines, index, $1)
        cause["shellCommand"] ||= command if command

      when /^\s*Verification of component '(.+)' failed.\s*$/
        cause["tests"] ||= {}
        cause["tests"]["chef verify"] ||= []
        cause["tests"]["chef verify"] << $1

      when /^CHEF-ACCEPTANCE::\[[^\]]+\]\s+\|(.+)\|\s*$/
        index, results = JenkinsHelpers.extract_chef_acceptance_result(lines, index)
        failures = results.select { |result| result["error"] == "Y" && result["command"] != "Total" }
        if failures.any?
          cause["tests"] ||=  {}
          cause["tests"]["chef-acceptance"] ||= []
          failures.each do |failure|
            cause["tests"]["chef-acceptance"] << "#{failure["suite"]} (#{failure["command"]})"
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

  def extract_suspicious_blocks(run, cause, context: 3)
    current_block = nil
    suspicious_blocks = {}
    lines.each_with_index do |line,index|
      range = nil

      case line
      when /The --deployment flag requires a/,
           /EACCES/,
           /\bERROR\b/,
           /\bFATAL\b/,
           /Errno::ECONNRESET/,
           /Permission denied/i,
           /Connection timed out/i,
           /Failed to complete (.*) action:/i

        range = index..index
      end

      if range
        # Add context
        range = (range.min-context)..(range.max+context)
        # If we're part of the range-being-emitted, extend the range
        if current_block && range.min <= current_block.end+1
          (current_block.max+1).upto(range.max) do |i|
            suspicious_blocks[current_block.min] << lines[i]
          end
          current_block = current_block.min..range.max
        else
          suspicious_blocks[range.min] = ""
          range.each do |i|
            suspicious_blocks[range.min] << lines[i]
          end
          current_block = range
        end
      end
    end
    cause["suspiciousBlocks"] = suspicious_blocks unless suspicious_blocks.empty?
  end

  # /home/jenkins/workspace/chefdk-build/architecture/x86_64/platform/debian-6/project/chefdk/role/builder/omnibus/vendor/bundle/ruby/2.1.0/bundler/gems/omnibus-7c98e2bbceb7/lib/omnibus/util.rb:101:in `rescue in shellout!'
  #   /home/jenkins/workspace/chefdk-build/architecture/x86_64/platform/debian-6/project/chefdk/role/builder/omnibus/vendor/bundle/ruby/2.1.0/bundler/gems/omnibus-7c98e2bbceb7/lib/omnibus/util.rb:97:in `shellout!'
  #   /home/jenkins/workspace/chefdk-build/architecture/x86_64/platform/debian-6/project/chefdk/role/builder/omnibus/vendor/bundle/ruby/2.1.0/bundler/gems/omnibus-7c98e2bbceb7/lib/omnibus/fetchers/git_fetcher.rb:263:in `revision_from_remote_reference'
  #   /home/jenkins/workspace/chefdk-build/architecture/x86_64/platform/debian-6/project/chefdk/role/builder/omnibus/vendor/bundle/ruby/2.1.0/bundler/gems/omnibus-7c98e2bbceb7/lib/omnibus/fetchers/git_fetcher.rb:237:in `resolve_version'
  #   /home/jenkins/workspace/chefdk-build/architecture/x86_64/platform/debian-6/project/chefdk/role/builder/omnibus/vendor/bundle/ruby/2.1.0/bundler/gems/omnibus-7c98e2bbceb7/lib/omnibus/fetcher.rb:186:in `resolve_version'
  #   /home/jenkins/workspace/chefdk-build/architecture/x86_64/platform/debian-6/project/chefdk/role/builder/omnibus/vendor/bundle/ruby/2.1.0/bundler/gems/omnibus-7c98e2bbceb7/lib/omnibus/software.rb:827:in `to_manifest_entry'
  #   /home/jenkins/workspace/chefdk-build/architecture/x86_64/platform/debian-6/project/chefdk/role/builder/omnibus/vendor/bundle/ruby/2.1.0/bundler/gems/omnibus-7c98e2bbceb7/lib/omnibus/software.rb:115:in `manifest_entry'
  #   /home/jenkins/workspace/chefdk-build/architecture/x86_64/platform/debian-6/project/chefdk/role/builder/omnibus/vendor/bundle/ruby/2.1.0/bundler/gems/omnibus-7c98e2bbceb7/lib/omnibus/software.rb:986:in `fetcher'
  #   /home/jenkins/workspace/chefdk-build/architecture/x86_64/platform/debian-6/project/chefdk/role/builder/omnibus/vendor/bundle/ruby/2.1.0/bundler/gems/omnibus-7c98e2bbceb7/lib/omnibus/software.rb:842:in `fetch'
  #   /home/jenkins/workspace/chefdk-build/architecture/x86_64/platform/debian-6/project/chefdk/role/builder/omnibus/vendor/bundle/ruby/2.1.0/bundler/gems/omnibus-7c98e2bbceb7/lib/omnibus/project.rb:1067:in `block (3 levels) in download'
  #   /home/jenkins/workspace/chefdk-build/architecture/x86_64/platform/debian-6/project/chefdk/role/builder/omnibus/vendor/bundle/ruby/2.1.0/bundler/gems/omnibus-7c98e2bbceb7/lib/omnibus/thread_pool.rb:64:in `call'
  #   /home/jenkins/workspace/chefdk-build/architecture/x86_64/platform/debian-6/project/chefdk/role/builder/omnibus/vendor/bundle/ruby/2.1.0/bundler/gems/omnibus-7c98e2bbceb7/lib/omnibus/thread_pool.rb:64:in `block (4 levels) in initialize'
  #   /home/jenkins/workspace/chefdk-build/architecture/x86_64/platform/debian-6/project/chefdk/role/builder/omnibus/vendor/bundle/ruby/2.1.0/bundler/gems/omnibus-7c98e2bbceb7/lib/omnibus/thread_pool.rb:62:in `loop'
  #   /home/jenkins/workspace/chefdk-build/architecture/x86_64/platform/debian-6/project/chefdk/role/builder/omnibus/vendor/bundle/ruby/2.1.0/bundler/gems/omnibus-7c98e2bbceb7/lib/omnibus/thread_pool.rb:62:in `block (3 levels) in initialize'
  #   /home/jenkins/workspace/chefdk-build/architecture/x86_64/platform/debian-6/project/chefdk/role/builder/omnibus/vendor/bundle/ruby/2.1.0/bundler/gems/omnibus-7c98e2bbceb7/lib/omnibus/thread_pool.rb:61:in `catch'
  #   /home/jenkins/workspace/chefdk-build/architecture/x86_64/platform/debian-6/project/chefdk/role/builder/omnibus/vendor/bundle/ruby/2.1.0/bundler/gems/omnibus-7c98e2bbceb7/lib/omnibus/thread_pool.rb:61:in `block (2 levels) in initialize'
  def extract_stacktrace(lines, index)
    stacktrace = []

    # Go backwards up the file until we stop seeing stacktrace lines
    while index >= 0
      trace_line = massage_ruby_stacktrace_line(lines[index])
      break unless trace_line
      # We are traveling backwards through the file, so we push new things at the top
      stacktrace.unshift(trace_line)
      index -= 1
    end

    [ index+1, skip_useless_stacktrace_lines(stacktrace) ]
  end

  # D      ------Backtrace-------
  # D      /home/jenkins/workspace/chef-test/architecture/x86_64/platform/acceptance/project/chef/role/tester/acceptance/vendor/bundle/ruby/2.1.0/gems/winrm-fs-0.4.2/lib/winrm-fs/core/file_transporter.rb:394:in `parse_response'
  # D      /home/jenkins/workspace/chef-test/architecture/x86_64/platform/acceptance/project/chef/role/tester/acceptance/vendor/bundle/ruby/2.1.0/gems/winrm-fs-0.4.2/lib/winrm-fs/core/file_transporter.rb:203:in `check_files'
  # D      /home/jenkins/workspace/chef-test/architecture/x86_64/platform/acceptance/project/chef/role/tester/acceptance/vendor/bundle/ruby/2.1.0/gems/winrm-fs-0.4.2/lib/winrm-fs/core/file_transporter.rb:80:in `block in upload'
  # D      /opt/chefdk/embedded/lib/ruby/2.1.0/benchmark.rb:279:in `measure'
  # D      ----------------------
  def extract_kitchen_stacktrace(lines, index)
    stacktrace = []
    while true
      # ---------------
      break if lines[index] =~ /^\s*-+\s*/

      trace_line = massage_ruby_stacktrace_line(lines[index])
      # If something went wrong and we aren't seeing stack traces, stop.
      break unless trace_line
      stacktrace << trace_line
      index += 1
    end
    skip_useless_stacktrace_lines(stacktrace)
  end

  # Get rid of the annoying project/workspace stuff at the beginning of most lines
  def massage_ruby_stacktrace_line(trace_line)
    trace_line = trace_line.strip
    if trace_line =~ /(\S+)(:\d+:in `.+'.*)/
      filename = $1
      rest_of_line = $2
      # /home/jenkins/workspace/chef-test/architecture/x86_64/platform/acceptance/project/chef/role/tester/acceptance/vendor/bundle/ruby/2.1.0/gems/winrm-fs-0.4.2/lib/winrm-fs/core/file_transporter.rb:394:in `parse_response'
      # -> acceptance/vendor/bundle/ruby/2.1.0/gems/winrm-fs-0.4.2/lib/winrm-fs/core/file_transporter.rb:394:in `parse_response'
      if filename =~ /[\/\\]architecture[\/\\][^\/\\]+[\/\\]platform[\/\\][^\/\\]+[\/\\]project[\/\\][^\/\\]+[\/\\]role[\/\\][^\/\\]+[\/\\](.+)/
        filename = $1
      end
      "#{filename}#{rest_of_line}"
    else
      nil
    end
  end

  def skip_useless_stacktrace_lines(stacktrace)
    # Skim useless things from the top
    index = stacktrace.size - 1
    # Always leave the top one on even if it seems useless. Never make it empty
    while index > 0
      case stacktrace[index]
      when /\bthread_pool\.rb:/
        stacktrace.pop
      else
        # It's not a skippable, stop skipping things
        break
      end

      index -= 1
    end
    stacktrace
  end

  def extract_shell_command(lines, index, exit_status)
    start_index = index
    command = { "exitStatus" => exit_status }

    # The following shell command exited with status 128:
    index += 1

    #
    #     $ git ls-remote "http://git.savannah.gnu.org/r/config.git" "master*"
    index += 1 while lines[index].chomp == ""
    command["command"] = lines[index].strip
    index += 1
    # Get rid of the $
    command["command"] = $1 if command["command"] =~ /^\s*\$\s*(.+)/
    command["command"] = command["command"].strip

    #
    # Output:
    #
    #     (nothing)
    #
    # Error:
    index += 1 while lines[index].strip == ""
    unless lines[index].chomp == "Output:"
      return nil
    end
    index += 1
    index += 1 while lines[index].chomp == ""
    return nil unless lines[index].start_with?("    ")
    command["stdout"] = lines[index][4..-1]
    index += 1
    while lines[index].chomp != "Error:"
      command["stdout"] << lines[index]
      index += 1
    end
    command["stdout"] = command["stdout"].strip
    command.delete("stdout") if command["stdout"] == "(nothing)"

    # Error:
    #
    #     fatal: unable to access 'http://git.savannah.gnu.org/r/config.git/': Failed connect to git.savannah.gnu.org:80; Operation now in progress
    index += 1
    index += 1 while lines[index].chomp == ""
    return nil unless lines[index].start_with?("    ")
    command["stderr"] = lines[index][4..-1]
    index += 1
    while lines[index].chomp != ""
      command["stderr"] << lines[index]
      index += 1
    end
    command["stderr"] = command["stderr"].strip
    command.delete("stderr") if command["stderr"] == "(nothing)"

    command
  end
end
