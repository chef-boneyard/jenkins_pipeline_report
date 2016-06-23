require_relative "jenkins_object"

module JenkinsPipelineReport
  module Jenkins
    class User < JenkinsObject
      def initialize(server, id)
        @server = server
        @id = id
      end

      #
      # The server this user is on.
      #
      # @return [Server] The server this user is on.
      #
      attr_reader :server

      #
      # The user ID (username).
      #
      # @return [String] The user ID (username).
      #
      attr_reader :id

      #
      # The path to this user on the server (/user/ID).
      #
      # @return [String] The path to this user.
      #
      def path
        "/user/#{id}"
      end

      #
      # The URL to the user.
      #
      # @return [String] The URL to the user.
      #
      def url
        File.join(server.url, path)
      end

      #
      # User properties.
      #
      # @return [Hash<String,Object>] User properties.
      #
      def properties
        properties = {}
        property_data = data("property")
        if property_data
          property_data.each do |properties_data|
            properties_data.each do |key, value|
              if properties[key].is_a?(Array)
                if value.is_a?(Array)
                  properties[key] = properties[key] + value
                else
                  properties[key] << value
                end
              else
                properties[key] = value
              end
            end
          end
        end
        properties
      end

      #
      # User full name.
      #
      def full_name
        data("fullName")
      end

      #
      # User email address.
      #
      # @return [Array<String>] The user's email address.
      #
      def address
        properties["address"]
      end

      #
      # List of fields to get from the server for a user.
      #
      FIELDS=%w{id fullName description property[*[*[*]]]}
    end
  end
end
