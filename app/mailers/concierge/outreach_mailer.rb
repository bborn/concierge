module Concierge
  # The generic email channel's mailer. Plain, dependency-free, and CAN-SPAM
  # aware: every message carries a one-click List-Unsubscribe header and link.
  class OutreachMailer < ApplicationMailer
    def notify
      @payload  = params[:payload]
      @body     = @payload[:body]
      to        = params[:to]
      @token    = params[:unsubscribe_token]

      headers["List-Unsubscribe"] = "<#{unsubscribe_url(@token)}>" if @token
      headers["List-Unsubscribe-Post"] = "List-Unsubscribe=One-Click" if @token

      mail(to: to, subject: params[:subject_line] || "A note from your account team")
    end

    private

    def unsubscribe_url(token)
      Concierge::Engine.routes.url_helpers.unsubscribe_url(
        token: token,
        host: Concierge.config.mailer_host || "example.com"
      )
    end
  end
end
