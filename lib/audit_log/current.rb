# frozen_string_literal: true

require "active_support/current_attributes"

module AuditLog
  # The audit identity for the current unit of work.
  #
  # Deliberately holds PRIMITIVES, not an ActiveRecord object. Two consequences,
  # both of which matter (plan §6.2):
  #
  #   1. A background job can populate the full audit identity with no database
  #      query and no ActiveJob::DeserializationError if the user was deleted
  #      between enqueue and perform.
  #   2. The label the trigger writes and the label the event subscriber writes
  #      are guaranteed to be the same string, because both read `actor_label`,
  #      which is computed exactly once per entry point.
  #
  # Reset by the Rails executor at the end of every request and job, so nothing
  # leaks between units of work on a shared connection.
  class Current < ActiveSupport::CurrentAttributes
    attribute :request_id, :caused_by_request_id
    attribute :actor, :actor_type, :actor_id, :actor_label
    attribute :ip, :user_agent, :source

    # config.default_dimensions, memoised for the unit of work. It is safe to
    # cache here for the same reason the lambda takes no arguments: nothing about
    # its value can vary with the event, so computing it once per unit of work
    # rather than once per event is a pure saving -- and it is also what
    # GUARANTEES two events in one unit of work cannot disagree about the tenant.
    # DESIGN §23.
    attribute :default_dimensions

    # Convenience writer for entry points that have the record in hand. Calling
    # this is the only place ActorLabel runs -- never from the transaction hook,
    # which is far too hot to query from.
    def actor=(record)
      super
      self.actor_type  = record&.class&.name
      self.actor_id    = record&.id
      self.actor_label = AuditLog::ActorLabel.for(record)
    end

    # Note that a nil actor leaves actor_label NULL rather than storing the
    # string "System". The distinction matters: NULL means "no correlated actor",
    # which is what an out-of-band write is, and the UI renders that as System at
    # DISPLAY time. Writing "System" into the column instead would make a console
    # session indistinguishable from a genuine scheduled system action.

  end
end
