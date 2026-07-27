module Concierge
  module ApplicationHelper
    # What to call this subject on screen — the host's +config.subject_label+ if
    # it has one, else the key the engine has always printed (`account#135`).
    #
    # Display only. The row is still found, scoped and audited by
    # (subject_type, subject_id); this string is never read back as an
    # identifier. Never wrap it in +raw+ or +html_safe+: it is host-supplied text
    # rendered into the engine's own HTML, and ERB escaping it is the defence.
    # +fallback+ is for the one screen that printed the pair in some other shape
    # ("account 135") before this hook existed and must keep printing exactly
    # that for a host which never sets one.
    def subject_label(record, fallback: nil)
      concierge_subject_labels.label_for(record, fallback: fallback)
    end

    # The same, for a screen that holds the key pair rather than a row.
    def subject_label_for_key(type, id, fallback: nil)
      concierge_subject_labels.label(type, id, fallback: fallback)
    end

    private

    # One resolver per request: the view context is built per request, so this
    # instance variable *is* a request-scoped memo. It is what keeps a hundred-row
    # queue from making a hundred host lookups.
    def concierge_subject_labels
      @concierge_subject_labels ||= Concierge::SubjectLabel::Resolver.new
    end
  end
end
