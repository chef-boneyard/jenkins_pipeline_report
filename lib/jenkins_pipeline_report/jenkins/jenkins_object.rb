module JenkinsPipelineReport
  module Jenkins
    class JenkinsObject
      # Get the data for this object. If we've been invalidated, we will fetch.
      # If not, we'll load the data from disk if we have it, and fetch if this
      # is the first time (or if we don't cache this object to disk).
      def data(field=nil)
        @data = nil if @data && invalidated?
        if field
          # If something is already loaded, use it!
          return @data[field] if @data
          return static_data[field] if static_data && static_data[field]
          data[field]
        else
          return @data if @data
          load!
        end
      end

      # Get static (unchanging) data. Does not honor invalidation, since static
      # data is assumed not to change. This will not cause a load orfetch if
      # someone else (such as a parent job or build or server) has given us
      # static data already. If we have loaded our own data, that will be used
      # in preference.
      def static_data(field=nil)
        # We don't care about invalidation for static fields
        if field
          # If something is already loaded, use it!
          return @data[field] if @data
          static_data[field]
        else
          return @data if @data
          return @static_data if @static_data
          load!
        end
      end

      # Invalidate the data so it will be fetched the next time it is loaded.
      # Note: invalidating does not necessarily unload data; static_data
      # does not change so attempts to read it will not force a fetch.
      def invalidate
        @cache_version = -1
      end

      # Tell whether we've been invalidated and will cause a fetch.
      def invalidated?
        cache.cache_version == cache_version
      end

      # Load the data (or fetch the data remotely if we don't have it or it is
      # out of date).
      def load!
        load_data unless cache.invalidated?(self)
        fetch_data
      end

      # Directly refresh the data from the server.
      def refresh!
        fetch_data
      end

      def static_data=(value)
        @static_data = value unless @data
      end

      def cache
        server.cache
      end

      attr_reader :cache_version

      private

      def load_data
        data = cache.read_cache(url)
        if data
          @data = data
          @static_data = nil
          @cache_version = cache.cache_version
          updated_data(data)
        end
        data
      end

      def fetch_data(&validate)
        data = server.api_get(path, jenkins_query)
        # Validate should raise an exception if the data is bad. We try not to
        # cache bad data (and overwrite the good!).
        validate.call(data) if validate
        @data = data
        @static_data = nil
        @cache_version = cache.cache_version
        if should_cache?
          cache.write_cache(url, @data)
        else
          cache.delete_cache(url)
        end
        updated_data(data)
        data
      end

      # Override this in subclasses to be called on either fetch_data or load_data
      def updated_data(data)
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
