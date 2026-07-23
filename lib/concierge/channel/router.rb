module Concierge
  module Channel
    # Picks a channel for a delivery: honor an explicit request, else the first
    # configured + available channel in the host's declared preference order.
    # Returns nil when nothing can reach the subject (the caller no-ops).
    class Router
      def initialize(channels: Concierge.config.channels)
        @channels = channels || []
      end

      # @param preferred [Symbol, String, nil] a specific channel name to try
      #   first. Coerced to a Symbol so a String-valued routine channel
      #   ("email") matches a channel's Symbol #name (:email).
      def pick(subject, preferred: nil)
        preferred = preferred&.to_sym
        ordered(preferred).each do |channel_class|
          channel = channel_class.new(subject: subject)
          return channel if channel.configured? && channel.available_for?(subject)
        end
        nil
      end

      private

      def ordered(preferred)
        return @channels unless preferred

        pref = @channels.find { |c| c.new(subject: nil).name == preferred }
        pref ? [ pref, *(@channels - [ pref ]) ] : @channels
      end
    end
  end
end
