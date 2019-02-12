module Capybara::Cuprite
  class Browser
    module Net
      def authorize(user, password)
        @username, @password = user, password
        intercept_request("*")
      end

      def intercept_request(patterns)
        patterns = Array(patterns).map { |p| { urlPattern: p } }
        @client.command("Network.setRequestInterception", patterns: patterns)
      end

      def continue_request(interception_id, options = nil)
        options ||= {}
        options = options.merge(interceptionId: interception_id)
        @client.command("Network.continueInterceptedRequest", **options)
      end

      private

      def subscribe_events
        super if defined?(super)

        @client.subscribe("Network.loadingFailed") do |params|
          # Free mutex as we aborted main request we are waiting for
          if params["requestId"] == @request_id && params["canceled"] == true
            signal
            @client.command("DOM.getDocument", depth: 0)
          end
        end

        @client.subscribe("Network.requestIntercepted") do |params|
          @authorized_ids ||= []
          url = params.dig("request", "url")
          interception_id = params["interceptionId"]

          if params["authChallenge"]
            response =
              if @authorized_ids.include?(interception_id)
                { response: "CancelAuth" }
              elsif @username && @password
                { response: "ProvideCredentials",
                  username: @username,
                  password: @password }
              else
                { response: "CancelAuth" }
              end

            @authorized_ids << interception_id
            continue_request(interception_id, authChallengeResponse: response)
          elsif @browser.url_blacklist && !@browser.url_blacklist.empty?
            if @browser.url_blacklist.any? { |r| r.match(url) }
              continue_request(interception_id, errorReason: "Aborted")
            else
              continue_request(interception_id)
            end
          elsif @browser.url_whitelist && !@browser.url_whitelist.empty?
            if @browser.url_whitelist.any? { |r| r.match(url) }
              continue_request(interception_id)
            else
              continue_request(interception_id, errorReason: "Aborted")
            end
          else
            continue_request(interception_id)
          end
        end
      end
    end
  end
end
