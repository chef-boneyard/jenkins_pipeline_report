module JenkinsPipelineReport
  module Report
    class TimingExtractor
      #
      # Handles step detection in a linear log.
      #
      class Step
        def initialize(name, start_time:, start_index:, parent: nil)
          raise ArgumentError, "name must be a string" unless name.is_a?(String)
          raise ArgumentError, "start_time cannot be nil" unless start_time
          raise ArgumentError, "start_index must be an integer" unless start_index.is_a?(Fixnum)
          @name = name
          @display = name
          @start_time = start_time
          @end_time = start_time
          @start_index = start_index
          @end_index = start_index
          @parent = parent
          @children = {}
          @open_children = {}
          # Everything except children of the root are anchored
          @anchored = !(parent && !parent.parent)
        end

        attr_reader :name
        attr_accessor :display
        def start_time
          @start_time = Time.parse(@start_time) if @start_time.is_a?(String)
          @start_time
        end
        def end_time
          @end_time = Time.parse(@end_time) if @end_time.is_a?(String)
          @end_time
        end
        def duration
          (end_time - start_time).to_f
        end
        attr_reader :start_index
        attr_reader :end_index
        attr_accessor :parent
        attr_reader :children
        attr_reader :open_children
        def anchored?
          @anchored
        end

        #
        # Find out whether this is open (can be modified / added to)
        #
        def open?
          !!open_children
        end

        #
        # Get a particular open child with the given path
        #
        def get(*path)
          name = path.shift
          if name
            child = open_children[name]
            child ? child.get(*path) : nil
          else
            self
          end
        end

        #
        # Update (or create) a Step
        #
        def update(*path, time: nil, index: nil)
          @end_time = time if time
          @end_index = index if index
          # Update next child in path
          name = path.shift
          if name
            unless open_children[name]
              open_children[name] = Step.new(name, start_time: time, start_index: index, parent: self)
            end
            open_children[name].update(*path, time: time, index: index)
          else
            self
          end
        end

        #
        # Close a step, moving it to the appropriate place and allowing another
        # step of the same name to be created in open_children.
        #
        def close(*path)
          if path.any?
            child = get(*path)
            result = child.close if child
            return result
          end
          if open?
            open_children.each_value do |child|
              child.close
            end
            @open_children = nil

            # Tell the parent to remove us from it.
            if parent
              parent.close_child(self)
            end
          end
        end

        #
        # Closes all children *except* what's in the path. Used for exclusive steps.
        #
        def close_all_except(*open_path)
          open_name = open_path.shift
          if open_name
            open_children.each do |child_name, child|
              if child_name == open_name
                child.close_all_except(*open_path)
              else
                child.close
              end
            end
          end
        end

        #
        # Closes all children.
        #
        def close_all
          open_children.each_value { |child| child.close }
        end

        def to_s
          parent ? "#{parent.to_s}.#{display}" : display
        end

        #
        # Get well-formated timing information for this node, to be emitted
        # in the summary.
        #
        # @api private
        #
        def step_timing
          result = {}
          if children.any?
            first_child_start = children.map { |n,c| c.start_time }.min

            if start_time != first_child_start
              before = (first_child_start - start_time)
              result["before (setup time)"] = before unless before.abs < 10
            end

            children.each do |key, child|
              value = child.step_timing
              result[key] = value unless (value.is_a?(Numeric) && value < 10) || value == {}
            end

            last_child_end = children.map { |n,c| c.end_time }.max
            if end_time != last_child_end
              after = (end_time - last_child_end)
              result["after (cleanup time)"] = after unless after.abs < 10
            end
          end

          if result.empty?
            result = duration
          elsif duration > 10 && result.size > 1
            result = { "total" => duration }.merge(result)
          end
          if result.is_a?(Hash)
            result.each do |key, value|
              result[key] = BuildReport.format_duration(value) if value.is_a?(Numeric)
            end
          end
          result
        end

        #
        # Get the list of open steps
        #
        def open_steps
          result = {}
          open_children.each do |name, child|
            result[name] = child.open_steps
          end
          return nil if result.empty?
          result
        end

        #
        # Add a closed child to children. First removes it from open children,
        # then finds the best new home for it and adds it there.
        #
        # @api private
        #
        def close_child(child)
          # Remove from open children
          open_children.delete(child.name)

          new_parent = best_parent(self) unless child.anchored?
          new_parent ||= self

          new_parent.add_closed_child(child)
        end

        #
        # Add the closed child to this step, possibly giving it any other
        # children who can fit under it.
        #
        # @api private
        #
        def add_closed_child(child)
          # Let the child steal any other children (unless they are anchored)
          children.each_value do |other|
            next if other.anchored?
            # Find out if the child (or any of its children) can contain it.
            best = child.best_parent(other)
            # If so, give it away.
            best.add_closed_child(other) if best
          end

          # Add to parent's children (possibly creating a unique index for ourselves)
          key = child.display
          index = 1
          while children.has_key?(key)
            index += 1
            key = "#{child.display} #{index}"
          end
          child.parent = self
          children[key] = child
        end

        #
        # Get the best parent for this child (the smallest enclosing parent).
        #
        # @api private
        #
        def best_parent(step)
          if start_index <= step.start_index && end_index >= step.end_index
            # Return a matching child if there is one.
            children.each_value do |child|
              result = child.best_parent(step)
              return result if result
            end
            # No children match, so it's our child.
            return self
          end
        end
      end
    end
  end
end
