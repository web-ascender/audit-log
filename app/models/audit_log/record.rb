# frozen_string_literal: true

module AuditLog
  # Both audit models are APPEND-ONLY from the application's point of view.
  #
  # `readonly?` is keyed on `persisted?` rather than hardcoded to true, because
  # ActiveRecord::Persistence#create_or_update raises ReadOnlyRecord for inserts
  # too -- a flat `def readonly? = true` would break EventSubscriber's create!.
  # Keying on persisted? gives exactly the rule wanted: rows may be inserted,
  # never updated or destroyed. It catches the realistic failure -- a developer
  # wiring a form or a data fix against the wrong model -- at no operational cost.
  #
  # Database-level enforcement (REVOKE UPDATE, DELETE + a rejecting trigger) is
  # deliberately not enabled here; it is an additive upgrade needing no schema
  # change. See plan §12.
  class Record < ActiveRecord::Base
    self.abstract_class = true

    # The real primary key is the composite (id, occurred_at) that Postgres
    # requires on a partitioned table. Declaring :id keeps ActiveRecord's finders
    # and `id` reader behaving normally; nothing writes through these models, so
    # the composite key never has to surface.
    def self.inherited(subclass)
      super
      subclass.primary_key = :id
    end

    def readonly?
      persisted?
    end
  end
end
