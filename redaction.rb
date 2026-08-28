# frozen_string_literal: true

module AuditLog
  # Value-level redaction. DESIGN §13, ROLLOUT Q5.
  #
  # An audit log holds old values of fields that may be personal data, which puts
  # R7 (immutable) in direct tension with an erasure request. The resolution is
  # not to delete rows:
  #
  #   * The STRUCTURAL record is permanent -- who changed which field, on which
  #     record, when, in which request. That survives untouched.
  #   * The VALUES are replaced with a marker naming the authorization.
  #   * The redaction is itself an audited action, written in the same
  #     transaction. Regulators want a record that data was removed and why; a
  #     silent hole is the thing to avoid.
  #
  # This is the ONLY operation permitted to modify audit rows, which is why it
  # lives here and not in application code: "who redacted what, and under what
  # authority" is itself a reviewable surface. The models are readonly, so it
  # goes through raw SQL by necessity as well as by design.
  #
  # Keep it rare by keeping the worst fields out of the log entirely --
  # `config.default_excluded_columns` and the per-table exclusions in the
  # migration are the first line, and they cost nothing.
  module Redaction
    ACTION = "audit.redaction"

    class << self
      # Redact one record's values everywhere they appear.
      #
      # columns: nil redacts every column in the diff. Naming columns is the
      # better habit -- an erasure request is usually about an email address, not
      # about the fact that a status changed.
      def redact_record!(record_type:, record_id:, reason:, columns: nil,
                         actor: nil, connection: ActiveRecord::Base.connection)
        marker  = marker_for(reason)
        columns = Array(columns).map(&:to_s).presence

        connection.transaction do
          # Narrated FIRST and in the same transaction, so the log can never hold
          # a redaction that nothing accounts for -- and never an account of a
          # redaction that did not happen.
          AuditLog.notify(ACTION,
                          reason: reason,
                          target_type: record_type,
                          target_id: record_id,
                          columns: columns,
                          redacted_by: AuditLog::ActorLabel.for(actor))

          {
            changes: redact_diffs!(record_type, record_id, columns, marker, connection),
            events:  redact_event_payloads!(record_type, record_id, marker, connection),
            marker:  marker
          }
        end
      end

      # Pseudonymize an ACTOR: replace the snapshotted label, keep actor_type and
      # actor_id. Their activity stays attributable to a stable identifier and
      # stays countable, which is what an audit trail is for -- it simply stops
      # naming them.
      def redact_actor!(actor_type:, actor_id:, reason:,
                        actor: nil, connection: ActiveRecord::Base.connection)
        marker = marker_for(reason)

        connection.transaction do
          AuditLog.notify(ACTION,
                          reason: reason,
                          target_type: actor_type,
                          target_id: actor_id,
                          columns: ["actor_label"],
                          redacted_by: AuditLog::ActorLabel.for(actor))

          counts = %w[audit_changes audit_events].to_h do |table|
            [table, connection.exec_update(<<~SQL).to_i]
              UPDATE #{table} SET actor_label = #{connection.quote(marker)}
              WHERE actor_type = #{connection.quote(actor_type)}
                AND actor_id   = #{connection.quote(actor_id)}
                AND actor_label IS DISTINCT FROM #{connection.quote(marker)}
            SQL
          end

          { changes: counts["audit_changes"], events: counts["audit_events"], marker: marker }
        end
      end

      # What redact_record! would touch, without touching it.
      def preview(record_type:, record_id:)
        {
          changes: AuditLog::Change.for_record(record_type, record_id).count,
          events:  AuditLog::Event.for_subject(record_type, record_id).count,
          columns: AuditLog::Change.for_record(record_type, record_id)
                                   .pluck(:changed_columns).flatten.uniq.sort
        }
      end

      def marker_for(reason)
        raise Error, "a redaction needs a written reason" if reason.blank?

        "[redacted #{Time.now.utc.to_date.iso8601} per #{reason}]"
      end

      private

      # Rebuild the diff key by key, so untargeted columns keep their values and
      # -- critically -- every KEY survives. `changed_columns` is left alone for
      # the same reason: "the email address was changed at 14:02 by Jane" stays
      # provable after the address itself is gone. That is the whole design.
      #
      # DELIBERATELY NOT DATE-BOUNDED. Every other query in this library carries a
      # range so the planner can prune; this one must reach every partition or the
      # redaction is incomplete, which is a compliance failure rather than a slow
      # screen. Run it in a maintenance window on a large log.
      def redact_diffs!(record_type, record_id, columns, marker, connection)
        pair      = connection.quote([marker, marker].to_json)
        predicate = if columns
                      "AND changed_columns && #{connection.quote("{#{columns.join(",")}}")}::text[]"
                    end
        targeted  = if columns
                      "key = ANY(#{connection.quote("{#{columns.join(",")}}")}::text[])"
                    else
                      "true"
                    end

        connection.exec_update(<<~SQL).to_i
          UPDATE audit_changes SET diff = (
            SELECT jsonb_object_agg(
                     key,
                     CASE WHEN #{targeted} THEN #{pair}::jsonb ELSE diff -> key END)
            FROM jsonb_object_keys(diff) AS key
          )
          WHERE record_type = #{connection.quote(record_type)}
            AND record_id   = #{connection.quote(record_id)}
            AND diff <> '{}'::jsonb
            #{predicate}
        SQL
      end

      # An action's metadata is its raw payload and the likeliest place for a
      # verbatim copy of the same personal data; the summary is that payload
      # rendered into a sentence. Both go. `action`, `actor`, `occurred_at` and
      # `request_id` stay, so the narrative layer still says that something
      # happened to this record, by whom, and when.
      def redact_event_payloads!(record_type, record_id, marker, connection)
        connection.exec_update(<<~SQL).to_i
          UPDATE audit_events
          SET summary  = #{connection.quote(marker)},
              metadata = '{}'::jsonb
          WHERE subject_type = #{connection.quote(record_type)}
            AND subject_id   = #{connection.quote(record_id)}
            AND action <> #{connection.quote(ACTION)}
            AND summary IS DISTINCT FROM #{connection.quote(marker)}
        SQL
      end
    end
  end
end
