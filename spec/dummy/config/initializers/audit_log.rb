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
    description: "A new order was drafted.",
    subject: ->(p) { ["Order", p[:order_id]] },
    summary: ->(p) { "Drafted order #{p[:reference]} for #{p[:customer_name]}" }

  AuditLog::Registry.register "order.updated",
    description: "An existing draft order was edited.",
    subject: ->(p) { ["Order", p[:order_id]] },
    summary: ->(p) { "Edited order #{p[:reference]} (#{p[:line_count]} line items)" }

  AuditLog::Registry.register "order.submitted",
    description: "An order was submitted for fulfillment.",
    subject: ->(p) { ["Order", p[:order_id]] },
    summary: lambda { |p|
      "Submitted order #{p[:reference]} for #{p[:customer_name]} — " \
        "#{p[:line_count]} line items, #{ActiveSupport::NumberHelper.number_to_currency(p[:total_cents].to_i / 100.0)}"
    }

  AuditLog::Registry.register "order.approved",
    description: "An order was approved.",
    subject: ->(p) { ["Order", p[:order_id]] },
    summary: ->(p) { "Approved order #{p[:reference]}" }

  AuditLog::Registry.register "order.cancelled",
    description: "An order was cancelled and its line items removed.",
    subject: ->(p) { ["Order", p[:order_id]] },
    summary: ->(p) { "Cancelled order #{p[:reference]} (#{p[:reason]})" }

  AuditLog::Registry.register "order.deleted",
    description: "An order was destroyed, cascading to its line items and shipments.",
    subject: ->(p) { ["Order", p[:order_id]] },
    summary: ->(p) { "Deleted order #{p[:reference]} and everything under it" }

  AuditLog::Registry.register "order.shipped",
    description: "A shipment was recorded against an order by a background job.",
    subject: ->(p) { ["Order", p[:order_id]] },
    summary: ->(p) { "Shipped order #{p[:reference]} via #{p[:carrier]} (#{p[:tracking_number]})" }

  AuditLog::Registry.register "customer.created",
    subject: ->(p) { ["Customer", p[:customer_id]] },
    summary: ->(p) { "Added customer #{p[:name]}" }

  AuditLog::Registry.register "customer.updated",
    subject: ->(p) { ["Customer", p[:customer_id]] },
    summary: ->(p) { "Updated customer #{p[:name]} (#{Array(p[:fields]).join(', ')})" }

  AuditLog::Registry.register "price.bulk_adjusted",
    description: "A bulk price change issued with update_all -- no Active Record " \
                 "callback ran, and the audit log captured every row anyway.",
    summary: ->(p) { "Adjusted prices by #{p[:percent]}% across #{p[:count]} products" }

  AuditLog::Registry.register "job.performed",
    description: "A background job ran. Closes the loop so job activity is never " \
                 "narrative-less in the reconciler.",
    summary: ->(p) { "Ran #{p[:job_class]}" }

  AuditLog::Registry.register "console.session_opened",
    description: "A console session was opened. Its writes carry request_id IS NULL.",
    summary: ->(p) { "Console session opened by #{p[:user]} — #{p[:reason]}" }

  AuditLog::Registry.register "audit.bypass",
    description: "Layer 1 was deliberately disabled for a bulk operation.",
    summary: ->(p) { "Audit logging bypassed by #{p[:by]}: #{p[:reason]}" }

  AuditLog::Registry.register "audit.bypass_completed",
    summary: ->(p) { "Bypass finished in #{p[:duration_ms]}ms: #{p[:reason]}" }

  # The one action that modifies audit rows, so it is also the one whose own row
  # matters most. Note what the summary keeps: what was redacted, from where, by
  # whom and under what authority -- none of which is the redacted data.
  AuditLog::Registry.register "audit.redaction",
    description: "Values were redacted from the audit log under an erasure request. " \
                 "The structural record -- which field changed, when, by whom -- is intact.",
    subject: ->(p) { [p[:target_type], p[:target_id]] },
    summary: lambda { |p|
      scope = Array(p[:columns]).presence&.join(", ") || "all recorded values"
      "Redacted #{scope} for #{p[:target_type]} ##{p[:target_id]} " \
        "(#{p[:reason]}), by #{p[:redacted_by] || "System"}"
    }
end
