# frozen_string_literal: true

# Everything the audit library needs to know about the DUMMY app.
#
# This file is the point of the dummy app. The library names no application
# constant, no authentication gem and no model; every coupling point is a lambda
# here. If the specs pass against an app with no Devise, no Solid Queue and no
# Pundit, that claim is true rather than merely asserted.
AuditLog.configure do |config|
  config.correlated_connections = %w[primary]

  # Plain session lookup -- see ApplicationController#current_user. The reference
  # app resolves the same thing through Devise, and the library cannot tell.
  config.actor_resolver = ->(controller) { controller.try(:current_user) }

  config.actor_label_resolver = ->(actor) { actor.to_label }

  config.actor_picker = lambda do |query|
    scope = User.order(:name)
    scope = scope.where("name ILIKE :q OR email ILIKE :q", q: "%#{query}%") if query.present?
    scope.limit(50)
  end

  # The audit screens are a privileged surface, so the dummy app gates them the
  # way a real one must. Several request specs depend on this refusing.
  config.authorize = lambda do |controller|
    unless controller.current_user&.auditor?
      raise ActionController::RoutingError, "Not authorized to view the audit log"
    end
  end

  config.bypass_allowlist = %w[CatalogImportJob]

  config.retention        = 7.years
  config.rollup_after     = 2.years

  # ------------------------------------------------------------------ dimensions
  # Host-defined facets. The row-derived half is declared beside the trigger, in
  # the migration -- `orders` alone, on customer_id, created_by_id and status.
  # This is the APP-SUPPLIED half.
  #
  # AMBIENT: applied to every audit_events row, merged UNDER anything a registry
  # entry declared. `app_version` is the honest example of what belongs here and
  # nowhere else -- no audited row carries it, and no action's payload should have
  # to. It takes NO ARGUMENTS, which is what makes it a different mechanism from a
  # registry `dimensions:` rather than a second spelling of one: it reads
  # application state, so its value is identical for every event in a unit of
  # work, and is therefore computed once per unit of work and memoised on Current.
  #
  # Note what a lambda applied to EVERY event does, because it is the one cost
  # worth seeing in a working example: every audit_events row now has a non-NULL
  # `dimensions`, so the partial index's predicate excludes nothing on that table.
  # That is self-selecting rather than a problem to fix -- a lambda for a facet
  # wanted on everything, a registry declaration for one wanted only where it will
  # be queried.
  config.default_dimensions = -> { { app_version: Rails.application.config.x.app_version } }

  # Which facets the auditor UI offers as a filter. INERT -- nothing here affects
  # what is recorded, and it can be added or dropped at any time with no effect on
  # a single stored row. `options:` reads from the app's OWN tables, never from
  # SELECT DISTINCT over a partitioned audit table; no `options:` means a free-text
  # input, which is right for app_version, where there is no list to offer.
  config.dimension_filters = {
    customer_id:   { label: "Customer",
                     options: -> { Customer.order(:name).limit(200).pluck(:name, :id) } },
    status:        { label: "Order status", options: -> { Order::STATUSES } },
    created_by_id: { label: "Drafted by",
                     options: -> { User.order(:name).limit(200).pluck(:name, :id) } },
    app_version:   { label: "App version" }
  }

  # Association labels are left entirely at their defaults, which is the point:
  # LineItem opts in with to_audit_label, Order/Product/Customer through an
  # overridden to_s, User through to_label, and Shipment not at all.
  #
  #   config.record_label_resolver / config.association_targets

  # Nothing extra: every table in this app is audited. `users` included -- see
  # the comment in the create_dummy_tables migration.
  config.unaudited_tables.merge!(
    # (nothing)
  )
end

# ---------------------------------------------------------------------------
# The registry: the finite, reviewable list of what this system considers an
# auditable action, and the home of each action's human sentence.
#
# An event with no entry here still reaches any observability subscriber -- it
# simply never becomes an audit_events row. That is how analytics stays out of
# the audit tables.
# ---------------------------------------------------------------------------
Rails.application.config.to_prepare do
  AuditLog::Registry.clear!

  AuditLog::Registry.register "order.created",
    requires: %i[order_id reference customer_name],
    description: "A new order was drafted.",
    subject: ->(p) { ["Order", p[:order_id]] },
    summary: ->(p) { "Drafted order #{p[:reference]} for #{p[:customer_name]}" }

  AuditLog::Registry.register "order.updated",
    requires: %i[order_id reference line_count],
    description: "An existing draft order was edited.",
    subject: ->(p) { ["Order", p[:order_id]] },
    summary: ->(p) { "Edited order #{p[:reference]} (#{p[:line_count]} line items)" }

  AuditLog::Registry.register "order.submitted",
    requires:   %i[order_id reference customer_name line_count total_cents],
    dimensions: %i[customer_id],
    description: "An order was submitted for fulfillment.",
    subject: ->(p) { ["Order", p[:order_id]] },
    summary: lambda { |p|
      "Submitted order #{p[:reference]} for #{p[:customer_name]} — " \
        "#{p[:line_count]} line items, #{ActiveSupport::NumberHelper.number_to_currency(p[:total_cents].to_i / 100.0)}"
    }

  AuditLog::Registry.register "order.approved",
    requires: %i[order_id reference approver],
    description: "An order was approved.",
    subject: ->(p) { ["Order", p[:order_id]] },
    summary: ->(p) { "Approved order #{p[:reference]}" }

  AuditLog::Registry.register "order.cancelled",
    requires: %i[order_id reference reason],
    description: "An order was cancelled and its line items removed.",
    subject: ->(p) { ["Order", p[:order_id]] },
    summary: ->(p) { "Cancelled order #{p[:reference]} (#{p[:reason]})" }

  # Deliberately the ONE entry with no `requires:`. The library says an entry
  # without it is unchecked, exactly as before this feature existed, and an app
  # where every entry declares one leaves that claim untested -- so this file
  # carries both shapes. It is also the only action that can be emitted with an
  # empty payload, which is the state shared/_event_payload renders as "nothing",
  # and audit_ui_spec needs somewhere to assert that. A real app would declare
  # %i[order_id reference] here.
  AuditLog::Registry.register "order.deleted",
    description: "An order was destroyed, cascading to its line items and shipments.",
    subject: ->(p) { ["Order", p[:order_id]] },
    summary: ->(p) { "Deleted order #{p[:reference]} and everything under it" }

  # THE ENTRY THAT DEMONSTRATES WHY THE EVENTS HALF EXISTS. This job's writes land
  # in `shipments`, which declares no facets, and in `orders`, which does -- but
  # the SHIPMENT rows would carry nothing, so a changes-only facet query would
  # report the order's status flip and not the shipment beside it. The event
  # carries customer_id for the whole unit of work, so the customer's feed picks
  # the activity up entire. Layer 1 catching what layer 2 cannot see and layer 2
  # saying what layer 1 cannot express, one level down.
  #
  # `dimensions:` DOES NOT IMPLY `requires:`, and this entry is where the dummy app
  # demonstrates it: customer_id is declared as a facet and is NOT required. An
  # emit that omits it writes the event with no customer_id facet and raises
  # nothing -- loose by default, which is what the whole feature is. An entry that
  # wants a facet enforced lists it in both, which customer.created below does.
  AuditLog::Registry.register "order.shipped",
    requires:   %i[order_id reference carrier tracking_number],
    dimensions: %i[customer_id],
    description: "A shipment was recorded against an order by a background job.",
    subject: ->(p) { ["Order", p[:order_id]] },
    summary: ->(p) { "Shipped order #{p[:reference]} via #{p[:carrier]} (#{p[:tracking_number]})" }

  # `customers` declares no facets on its trigger, so these two are reachable by a
  # customer_id filter ONLY through the events half. Between them and the `orders`
  # trigger, the dummy app exercises both directions of DESIGN §23's table.
  #
  # These are also the entries that carry a facet in BOTH `dimensions:` and
  # `requires:` -- the other shape, against order.shipped's. customer_id was
  # already required here because the summary cannot render without it, and
  # declaring it a facet as well changes nothing about that.
  AuditLog::Registry.register "customer.created",
    requires:   %i[customer_id name],
    dimensions: %i[customer_id],
    subject: ->(p) { ["Customer", p[:customer_id]] },
    summary: ->(p) { "Added customer #{p[:name]}" }

  AuditLog::Registry.register "customer.updated",
    requires:   %i[customer_id name],
    dimensions: %i[customer_id],
    subject: ->(p) { ["Customer", p[:customer_id]] },
    summary: ->(p) { "Updated customer #{p[:name]} (#{Array(p[:fields]).join(', ')})" }

  AuditLog::Registry.register "price.bulk_adjusted",
    requires: %i[percent count],
    description: "A bulk price change issued with update_all -- no Active Record " \
                 "callback ran, and the audit log captured every row anyway.",
    summary: ->(p) { "Adjusted prices by #{p[:percent]}% across #{p[:count]} products" }

  AuditLog::Registry.register "job.performed",
    requires: %i[job_class],
    description: "A background job ran. Closes the loop so job activity is never " \
                 "narrative-less in the reconciler.",
    summary: ->(p) { "Ran #{p[:job_class]}" }

  AuditLog::Registry.register "console.session_opened",
    requires: %i[user reason],
    description: "A console session was opened. Its writes carry request_id IS NULL.",
    summary: ->(p) { "Console session opened by #{p[:user]} — #{p[:reason]}" }

  AuditLog::Registry.register "audit.bypass",
    requires: %i[reason by],
    description: "Layer 1 was deliberately disabled for a bulk operation.",
    summary: ->(p) { "Audit logging bypassed by #{p[:by]}: #{p[:reason]}" }

  AuditLog::Registry.register "audit.bypass_completed",
    requires: %i[reason duration_ms],
    summary: ->(p) { "Bypass finished in #{p[:duration_ms]}ms: #{p[:reason]}" }

  # The one action that modifies audit rows, so it is also the one whose own row
  # matters most. Note what the summary keeps: what was redacted, from where, by
  # whom and under what authority -- none of which is the redacted data.
  AuditLog::Registry.register "audit.redaction",
    requires: %i[target_type target_id reason],
    description: "Values were redacted from the audit log under an erasure request. " \
                 "The structural record -- which field changed, when, by whom -- is intact.",
    subject: ->(p) { [p[:target_type], p[:target_id]] },
    summary: lambda { |p|
      scope = Array(p[:columns]).presence&.join(", ") || "all recorded values"
      "Redacted #{scope} for #{AuditLog::Identity.for(p[:target_type], p[:target_id])} " \
        "(#{p[:reason]}), by #{p[:redacted_by] || "System"}"
    }

  # The pair that narrates a deliberate hole in the change record (DESIGN §25).
  # AuditLog::Capture RAISES if either is missing rather than emitting nothing,
  # which is why these are the only two library actions whose absence is an error
  # instead of a silence.
  AuditLog::Registry.register "audit.capture_disabled",
    requires: %i[reason],
    description: "Layer 1 trigger capture was disabled. Field-level diffs stop " \
                 "being recorded from this point until capture is resumed.",
    summary: lambda { |p|
      "Audit capture disabled for #{Array(p[:tables]).size} tables: #{p[:reason]}"
    }

  # DELIBERATELY UNDECLARED, and the second of the dummy app's two. `requires:`
  # lists what an entry cannot RENDER without, and this one renders from nothing:
  # `disabled_at` is absent whenever the marker was unreadable, and the sentence
  # is complete without it. Declaring it here would contradict the entry, which is
  # the same argument that keeps `columns` out of `audit.redaction`'s list.
  AuditLog::Registry.register "audit.capture_resumed",
    description: "Layer 1 trigger capture was resumed. The window in between is a " \
                 "gap in the change record, and there is no backfill for it.",
    summary: lambda { |p|
      since = p[:disabled_at].presence
      "Audit capture resumed#{" (disabled since #{since})" if since}"
    }
end
