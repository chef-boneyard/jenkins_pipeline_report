module JenkinsPipelineReport
  module Helpers
    def self.reorder_fields(hash, start_fields=[], end_fields=[])
      # Allow user to pass single field name, upconvert to array
      start_fields = Array(start_fields)
      end_fields = Array(end_fields)

      reordered_hash = {}
      # Put start_fields first
      start_fields.each do |field|
        reordered_hash[field] = hash[field] if hash.has_key?(field)
      end
      # Everything else next
      hash.keys.sort.each do |field|
        reordered_hash[field] = hash[field] unless start_fields.include?(field) || end_fields.include?(field)
      end
      # End fields last
      end_fields.each do |field|
        reordered_hash[field] = hash[field] if hash.has_key?(field)
      end
      reordered_hash
    end

    def self.extract_chef_acceptance_results(excerpt)
      # CHEF-ACCEPTANCE::[2016-05-13 20:19:04 +0000] chef-acceptance run succeeded
      # CHEF-ACCEPTANCE::[2016-05-13 20:19:04 +0000] | Suite   | Command   | Duration | Error |
      # CHEF-ACCEPTANCE::[2016-05-13 20:19:04 +0000] | trivial | provision | 00:01:21 | N     |
      # CHEF-ACCEPTANCE::[2016-05-13 20:19:04 +0000] | trivial | verify    | 00:00:15 | N     |
      # CHEF-ACCEPTANCE::[2016-05-13 20:19:04 +0000] | trivial | destroy   | 00:00:07 | N     |
      # CHEF-ACCEPTANCE::[2016-05-13 20:19:04 +0000] | trivial | Total     | 00:01:58 | N     |
      # CHEF-ACCEPTANCE::[2016-05-13 20:19:04 +0000] | Run     | Total     | 00:01:58 | N     |
      results = []
      field_names = nil
      excerpt.each_line do |line|
        if line =~ /^CHEF-ACCEPTANCE::\[[^\]]+\]\s+\|(.+)\|\s*$/
          row = $1.split("|").map { |f| f.strip }
          if field_names
            results[-1] << Hash[field_names.zip(row)]
          else
            # If the current_result exists, this is a new section. Add a result
            # and parse field names
            field_names = row.map { |name| name.downcase }
            results << []
          end
        else
          # We're not in a result block anymore, so clear out field names
          field_names = nil
        end
      end
      results
    end
  end
end