# frozen_string_literal: true

module AuditLog
  # How a RECORDED IDENTITY -- a type and a primary key -- reads on a screen.
  #
  # "Order (id: 6064)", never "Order #6064". The `#` was dropped deliberately:
  # host applications overwhelmingly use it for their own identifier -- an
  # order number, an invoice number, a ticket reference -- and on an audit screen
  # a reader cannot tell the two apart. That ambiguity is the exact failure the
  # rest of this library is built against, since every one of these strings sits
  # beside a live-resolved label and its entire job is to be the part that is
  # unmistakably what the log recorded. `(id:)` says which number it is.
  #
  # ONE DEFINITION, because there were seven interpolations of `"#{type} ##{id}"`
  # across the engine, the library and two generator templates, and nothing made
  # them agree. The Changes tab and the Timeline tab of the same record screen
  # drifted apart the first time one of them was edited. Same lesson as
  # `ActorLabel.display`, whose hand-rolled copy dropped a nil branch and took a
  # screen down, and as `Change#operation_name`, which looked dead only because a
  # refactor had inlined it into three places.
  #
  # TWO OF THE CALLERS STORE their result rather than rendering it --
  # `Configuration#default_actor_label` snapshots into `audit_events.actor_label`
  # and `audit_changes.actor_label`, and a registry `summary:` is frozen at emit
  # time. Rows written before this change keep the spelling they were written
  # with, which is what a snapshot means and not a defect to repair. Do not add a
  # migration that rewrites them.
  #
  # There is deliberately NO `config.identity_format`. A host could set it back to
  # `#`, which is the ambiguity this exists to remove, and two applications would
  # then spell the same recorded fact differently. If it ever has to be
  # configurable, this module is the one place it would go.
  module Identity
    # The bare annotation, for a context that has ALREADY established the type --
    # a diff cell, where the column name says what the id points at. This is the
    # spelling `audit_value` and the generated `activity_value` have always used,
    # and the other two forms below are built to agree with it rather than the
    # other way round.
    def self.annotation(id) = "(id: #{id})"

    # A standalone identity: "Order (id: 6064)".
    def self.for(type, id) = "#{type} #{annotation(id)}"

    # An identity carrying a live-resolved label: "Grommet 10mm (Product id: 51)".
    #
    # THE ID IS NEVER DROPPED. The label is resolved from current state at display
    # time and the id is what the log recorded (DESIGN §11.8) -- a renderer that
    # keeps only the label turns an audit screen into a report of current state.
    # The parentheses always hold the recorded fact; the type appears inside them
    # only because nothing else on the line has said it.
    def self.labelled(label, type, id)
      label.present? ? "#{label} (#{type} id: #{id})" : self.for(type, id)
    end
  end
end
