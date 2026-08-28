# frozen_string_literal: true

module AuditLog
  # One per request. Discovers which diff columns are association ids, resolves
  # them to labels in batches, caches the answers, and -- the part that matters --
  # keeps four distinguishable outcomes distinguishable.
  #
  # WHY NOTHING IS CACHED AT PROCESS LEVEL. This holds host-application class
  # names, reflected from host-application models. A process-level cache of those
  # would go stale across a development code reload, which is exactly the trap
  # CLAUDE.md warns about for anything living outside lib/audit_log/app/. One
  # reflection call and one primary-key lookup per type per page is not a cost
  # worth a staleness bug, so every memo here dies with the request.
  class LabelResolver
    # The id points at nothing. On an audit screen that is INFORMATION, not an
    # error -- the referenced row was almost certainly deleted -- so it is stated
    # rather than swallowed.
    MISSING = :missing

    # The resolver raised. Deliberately NOT the same outcome as "no label
    # configured": one means the screen could not answer, the other means there
    # was never a question. Rendering them alike is the silent hole that
    # shared/_event_payload exists to avoid, and an UNRESCUED raise here would
    # take down the entire page -- see the actor_path(nil) note in CLAUDE.md.
    FAILED = :failed

    # A belongs_to whose target type is a sibling column in the same diff.
    POLYMORPHIC = :polymorphic

    # The record's own primary key. Never labelled: the Record cell beside it
    # already names the record, so a label here would repeat it.
    SELF_COLUMN = "id"

    def initialize(resolver: AuditLog.config.record_label_resolver)
      @resolver     = resolver
      @labels       = {}   # [type, id] => String | MISSING | FAILED
      @targets      = {}   # record_type => { column => type | POLYMORPHIC | false }
      @unlabelled   = Set.new
      @any_resolved = false
    end

    def enabled? = !@resolver.nil?

    # Did anything on this page actually get a label? Drives the one-line
    # disclosure: a screen that labelled nothing should not claim it did.
    def any_resolved? = @any_resolved

    # Resolve everything a page will ask for, in one pass per type.
    #
    # An OPTIMIZATION and nothing more. #for and #for_value resolve a miss on
    # demand, so a screen that forgets to warm renders identically and merely
    # issues more queries. Correctness never depends on remembering this call --
    # slow and correct over fast and wrong, same as RequestDrillDown.
    def warm(changes)
      return self unless enabled?

      wanted = Hash.new { |h, k| h[k] = [] }

      Array(changes).each do |change|
        wanted[change.record_type] << change.record_id

        each_association_value(change) { |type, id| wanted[type] << id }
      end

      wanted.each { |type, ids| load(type, ids) }
      self
    end

    # The label for a record identity -- the "LineItem #86" in the Record column.
    def for(type, id)
      return nil unless enabled?
      return nil if type.blank? || id.blank?

      key = [type.to_s, id]
      load(type.to_s, [id]) unless @labels.key?(key)
      @labels[key]
    end

    # The label for one side of one diff cell, or nil if this column is not an
    # association id at all.
    #
    # `side` matters only for a polymorphic column, where the type to resolve
    # against is whichever value the sibling _type column held on the SAME side of
    # the change. Resolving an old id against a new type would caption a row with
    # the wrong record entirely.
    def for_value(change, column, value, side:)
      return nil unless enabled?
      return nil unless value.is_a?(Integer)

      type = target_type(change, column, side: side)
      type ? self.for(type, value) : nil
    end

    private

    # Every (type, id) pair a change's diff refers to, for warming. Yields
    # nothing for a polymorphic column whose type it cannot determine.
    def each_association_value(change)
      diff = change.diff
      return unless diff.is_a?(Hash)

      diff.each do |column, pair|
        old_value, new_value = pair.is_a?(Array) ? pair : [nil, pair]

        [[old_value, :old], [new_value, :new]].each do |value, side|
          next unless value.is_a?(Integer)

          type = target_type(change, column, side: side)
          yield(type, value) if type
        end
      end
    end

    def target_type(change, column, side:)
      column = column.to_s
      return nil if column == SELF_COLUMN

      target = targets_for(change.record_type)[column]
      return nil if target.nil? || target == false
      return polymorphic_type(change, column, side: side) if target == POLYMORPHIC

      target
    end

    # A polymorphic belongs_to writes subject_id AND subject_type, and the trigger
    # put both in the same jsonb blob -- so the type is already in hand, with no
    # extra column and no extra query.
    #
    # It is in hand only when the _type column CHANGED, though: a diff holds
    # changed columns only, so an UPDATE touching just subject_id carries no type
    # and this returns nil. No label rather than a guessed one; reading the type
    # off the live record would caption a historical row with today's type.
    def polymorphic_type(change, column, side:)
      pair = change.diff[column.sub(/_id\z/, "_type")]
      return nil if pair.nil?

      values = pair.is_a?(Array) ? pair : [pair, pair]
      (side == :old ? values.first : values.last).presence
    end

    # column => target type for one record type: belongs_to reflection, with
    # config.association_targets merged over the top.
    #
    # class_name rather than klass.name, so a belongs_to pointing at a constant
    # that no longer exists yields an unresolvable string here instead of raising
    # while rendering. record_type is a snapshot written by the trigger, so a
    # renamed or deleted model is an ordinary case, not an exceptional one.
    def targets_for(record_type)
      @targets[record_type] ||= begin
        klass     = record_type.to_s.safe_constantize
        reflected =
          if klass.respond_to?(:reflect_on_all_associations)
            klass.reflect_on_all_associations(:belongs_to).each_with_object({}) do |assoc, out|
              out[assoc.foreign_key.to_s] = assoc.polymorphic? ? POLYMORPHIC : assoc.class_name
            end
          else
            {}
          end

        overrides = AuditLog.config.association_targets.fetch(record_type.to_s, {})
        reflected.merge(overrides.transform_keys(&:to_s))
      rescue StandardError => e
        warn_once("reflecting associations on #{record_type}", e)
        {}
      end
    end

    def load(type, ids)
      return if @unlabelled.include?(type)

      pending = ids.compact.uniq.reject { |id| @labels.key?([type, id]) }
      return if pending.empty?

      found =
        begin
          @resolver.call(type, pending)
        rescue StandardError => e
          warn_once("resolving labels for #{type}", e)
          pending.each { |id| @labels[[type, id]] = FAILED }
          return
        end

      # nil means "I do not label this type" -- remember it, and never ask again.
      # {} means "I do label it, and none of those ids exist", which is a genuine
      # MISSING. Collapsing the two would print "(not found)" against every id of
      # an un-opted-in model and announce deletions that never happened.
      if found.nil?
        @unlabelled << type
        return
      end

      by_id = found.each_with_object({}) { |(k, v), out| out[k.to_s] = v }

      pending.each do |id|
        label = by_id[id.to_s].presence
        @any_resolved ||= !label.nil?
        @labels[[type, id]] = label || MISSING
      end
    end

    # Logged, not raised. A label is decoration; the id beside it is the audit
    # record, and it is already on the screen. Silence would be wrong too, hence
    # FAILED rendering visibly in the cell.
    def warn_once(what, error)
      @warned ||= Set.new
      key = [what, error.class.name]
      return unless @warned.add?(key)

      Rails.logger&.warn("[AuditLog] label lookup failed while #{what}: #{error.class}: #{error.message}")
    end
  end
end
