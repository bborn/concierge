# A turn that fails now fails in a job, and a job cannot set a flash.
#
# While the reply ran inside the POST, "the model was overloaded" could be told
# to the customer in the redirect and nothing had to be written down: the row was
# never touched, so the message stayed unanswered and the composer came back.
# Once the turn moves off the request that story has no listener — the customer
# may be on another page, or none — so the failure has to be durable enough to
# still be on the card when they come back.
#
# Three states out of three columns, rather than a status enum:
#
#   reply_body nil                                  → nothing sent
#   reply_body, no replied_at, no reply_failed_at   → sent, agent is thinking
#   reply_body + replied_at                         → answered
#   reply_body + reply_failed_at                    → the turn failed; their words
#                                                     are kept so the retry is one
#                                                     click and not re-typing
class AddReplyFailedAtToInboxMessages < ActiveRecord::Migration[7.1]
  def change
    add_column :inbox_messages, :reply_failed_at, :datetime
  end
end
