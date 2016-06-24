module JenkinsPipelineReport
  module Jenkins
    class JenkinsObject
      def data(field=nil)
        @data = nil if @data && cache.invalidated?(self)
        if field
          # If something is already loaded, use it!
          return @data[field] if @data
          return static_data[field] if static_data && static_data[field]
          data[field]
        else
          return @data if @data
          load unless cache.invalidated?(self)
          fetch
        end
      end

      def static_data(field=nil)
        # We don't care about invalidation for static fields
        if field
          # If something is already loaded, use it!
          return @data[field] if @data
          return static_data[field] if static_data
          data(field)
        else
          return @data if @data
          return @static_data if @static_data
          load unless cache.invalidated?(self)
          fetch
        end
      end

      def static_data=(value)
        @static_data = value unless @data
      end

      def cache
        server.cache
      end

      attr_reader :valid_token

      private

      def load
        data = cache.read_cache(url)
        if data
          @data = data
          @static_data = nil
          @valid_token = cache.valid_token
          updated(data)
        end
        data
      end

      def fetch(&validate)
        data = server.api_get(path, jenkins_query)
        # Validate should raise an exception if the data is bad. We try not to
        # cache bad data (and overwrite the good!).
        validate.call(data) if validate
        @data = data
        @static_data = nil
        @valid_token = cache.valid_token
        if should_cache?
          cache.write_cache(url, @data)
        else
          cache.delete_cache(url)
        end
        updated(data)
        data
      end

      # Override this in subclasses to be called on either fetch or load
      def updated(data)
      end

      def jenkins_query
        "tree=#{self.class::FIELDS.join(",")}"
      end

      def should_cache?
        cache.should_cache?(self)
      end
    end
  end
end
