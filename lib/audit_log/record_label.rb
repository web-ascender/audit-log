# frozen_string_literal: true

module AuditLog
  # Renders a business record into the label an auditor reads NEXT TO its id.
  #
  # The sibling of ActorLabel, and deliberately its opposite in one respect.
  # ActorLabel SNAPSHOTS -- the label it produces is written onto every audit row
  # at the moment of the change -- because an actor label REPLACES the identity in
  # the actor column, and a live join there would let a rename retroactively
  # change what the audit log says happened (R6). Auditors read that as tampering.
  #
  # This one resolves LIVE, at display time, and that is safe for exactly one
  # reason: the label is ADDITIVE. The stored fact stays on the screen and the
  # label annotates it --
  #
  #     product_id    (not set)  ->  Grommet 10mm (id: 51)
  #
  # -- so nothing here is ever stored, and nothing here can rewrite history. The
  # screen discloses that labels are current state; the ids are what was recorded.
  #
  # OPT-IN, AND SILENT WHEN NOT. The chain ends in nil, NOT in "Product #51".
  # That is the other place this differs from ActorLabel, whose chain must end in
  # something because the actor column would otherwise be blank. Here the id is
  # already rendered, so a model that defines no hook must produce NO label and
  # leave the cell byte-identical to what it was before any of this existed.
  module RecordLabel
    # Shorter than ActorLabel::MAX_LENGTH (255): this sits inside a diff cell
    # alongside the id, not in a column of its own.
    MAX_LENGTH = 120

    # to_audit_label first, on purpose -- it lets a model show auditors something
    # different from what it shows the rest of the UI, which matters when the
    # everyday label embeds something you would rather not repeat across an audit
    # trail. to_label is the existing convention (Configuration#default_actor_label)
    # and comes second. A deliberately overridden to_s comes third: a method the
    # model's author wrote, not an inference this library made.
    #
    # There is deliberately NO fallback that sniffs a `name` or `title` column.
    # Guessing which column reads as a label is how a screen ends up confidently
    # captioning an id with the wrong string, and a confident wrong caption on an
    # audit screen is worse than no caption at all. to_audit_label is the seam for
    # saying it explicitly.
    def self.for(record)
      return nil if record.nil?

      label =
        if record.respond_to?(:to_audit_label) then record.to_audit_label
        elsif record.respond_to?(:to_label)    then record.to_label
        elsif overridden_to_s?(record.class)   then record.to_s
        end

      label.to_s.truncate(MAX_LENGTH).presence
    end

    # Can this class EVER produce a label? Answered from the class alone -- no
    # instance, no query, and no assumption that its table exists. That is what
    # lets LabelResolver skip a type outright instead of SELECTing a page of rows
    # only to discover every one of them yields nil, and it is why an application
    # that has opted nothing in pays nothing at all.
    #
    # Uses method_defined? rather than respond_to?, so a hook provided through
    # method_missing alone is not seen here and the type is pruned. Define the
    # method (or supply your own config.record_label_resolver) if that matters.
    def self.labelable?(klass)
      return false unless klass.is_a?(Class)

      klass.method_defined?(:to_audit_label) ||
        klass.method_defined?(:to_label) ||
        overridden_to_s?(klass)
    end

    # Kernel#to_s (or Object#to_s) as the owner means "not overridden". An
    # un-overridden Active Record model renders "#<Product:0x000000012f...>",
    # which is worse than no label at all.
    def self.overridden_to_s?(klass)
      owner = klass.instance_method(:to_s).owner
      owner != ::Kernel && owner != ::Object
    rescue NameError
      false
    end

    # The default config.record_label_resolver.
    #
    # BATCH BY CONSTRUCTION: one query per type per page, never one per cell. A
    # single-value ->(type, id) signature reads more nicely and guarantees an N+1
    # on a 50-row page, so the protocol does not offer one.
    #
    # Returns nil -- NOT {} -- for a type it does not label at all. The two are
    # different answers and LabelResolver renders them differently: {} means "this
    # type is labelled and none of those ids exist any more", while nil means
    # "this type never opted in". Reporting the second as the first would announce
    # a deletion that never happened, on every row of the screen.
    def self.batch(type, ids)
      klass = type.to_s.safe_constantize
      return nil unless labelable?(klass) && klass.respond_to?(:where)

      klass.where(id: ids).each_with_object({}) do |record, out|
        label = self.for(record)
        out[record.id] = label if label
      end
    end
  end
end
