# frozen_string_literal: true

# The scheduled-job demo. Enqueued by config/recurring.yml, so there is no
# enqueuing context at all: audit_origin comes back empty, the actor stays NULL,
# and JobContext derives source: "system" automatically. No base class, no
# per-job configuration -- an auditor just sees "the schedule did this" rather
# than "a user caused this".
class NightlyPriceReviewJob < ApplicationJob
  queue_as :default

  def perform(percent: 0)
    return if percent.zero?

    scope = Product.active
    count = scope.count

    # update_all: one UPDATE statement, zero Active Record callbacks. A
    # callback-based audit gem records NOTHING here. The trigger records one
    # audit_changes row per product, with the old and new price on each.
    scope.update_all("price_cents = (price_cents * #{100 + percent}) / 100")

    AuditLog.notify("price.bulk_adjusted", percent: percent, count: count)
  end
end
