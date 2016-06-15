module JenkinsPipelineReport
  # Lets you mark individual lines, and then run `each_block` to yield a list
  # of ranges representing those lines.
  class BlockMarker
    def marked
      @marked ||= []
    end

    def mark(min, max)
      min = 0 if min < 0
      min.upto(max).each { |i| marked[i] = true }
    end

    def each_block
      range_start = nil
      marked.each_with_index do |is_marked, i|
        if is_marked ||
           (marked[i-1] && marked[i+1]) || # Glue together ranges that differ by just one line
           range_start == i-1 # Never have a range that is exactly one line
          range_start ||= i
        else
          yield Range.new(range_start, i-1) if range_start
          range_start = nil
        end
      end
      yield Range.new(range_start, marked.size-1) if range_start
    end
  end
end
