# frozen_string_literal: true

# The job-correlation demo.
#
# Enqueued by a user clicking "Ship". At perform time it inherits Jane's actor
# identity -- so the rows it writes appear on her activity screen -- but mints a
# FRESH request_id and records the originating one as caused_by_request_id.
#
# Note the argument: an Order, passed as a GlobalID by ActiveJob. The audit
# identity does NOT ride here; it rides in its own `audit_origin` key, so job
# signatures stay untouched and a deleted user can never cause a
# DeserializationError on the audit payload.
class OrderFulfillmentJob < ApplicationJob
  queue_as :default

  CARRIERS = %w[UPS FedEx USPS].freeze

  def perform(order)
    tracking = "1Z#{SecureRandom.alphanumeric(12).upcase}"
    carrier  = CARRIERS.sample

    order.transaction do
      shipment = order.shipments.create!(
        carrier: carrier, tracking_number: tracking, status: "in_transit", shipped_at: Time.current
      )
      order.update!(status: "shipped")

      AuditLog.notify("order.shipped",
        order_id: order.id, reference: order.reference,
        carrier: carrier, tracking_number: tracking, shipment_id: shipment.id)
    end
  end
end
