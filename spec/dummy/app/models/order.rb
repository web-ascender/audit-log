# frozen_string_literal: true

class Order < ApplicationRecord
  STATUSES = %w[draft submitted approved shipped cancelled].freeze

  belongs_to :customer
  belongs_to :created_by, class_name: "User", optional: true

  has_many :line_items, dependent: :destroy
  # dependent: :delete_all issues a single DELETE and runs NO Active Record
  # callbacks -- so a callback-based audit gem records nothing here. The database
  # trigger records every row.
  has_many :shipments, dependent: :delete_all

  accepts_nested_attributes_for :line_items, allow_destroy: true, reject_if: :all_blank

  validates :reference, presence: true, uniqueness: true
  validates :status, inclusion: { in: STATUSES }

  before_validation :assign_reference, on: :create
  before_save :recalculate_total

  scope :open, -> { where.not(status: %w[cancelled shipped]) }

  def to_s = reference
  def total = total_cents / 100.0
  def editable? = status.in?(%w[draft submitted])

  # ---------------------------------------------------------------- layer 2
  # Layer 1 records that six rows changed. Only the application can say that
  # those six rows constituted "submitting an order", so the human narrative is
  # opt-in per action -- one notify call, inside the same transaction as the
  # work it describes, so a rollback discards both.

  def submit!
    transaction do
      update!(status: "submitted", submitted_at: Time.current)
      line_items.each { |item| item.update!(unit_price_cents: item.product.price_cents) }

      # customer_id is here as a FACET as well as evidence: order.submitted
      # declares it in `dimensions:`, so it is copied onto the event's own
      # dimensions column and stays in metadata besides. Copied, never moved --
      # Redaction empties metadata and does not reach the facet.
      AuditLog.notify("order.submitted",
        order_id: id, reference: reference, customer_name: customer.name,
        customer_id: customer_id,
        line_count: line_items.size, total_cents: total_cents)
    end
  end

  def approve!(by:)
    transaction do
      update!(status: "approved", approved_at: Time.current)
      AuditLog.notify("order.approved", order_id: id, reference: reference, approver: by.to_label)
    end
  end

  def cancel!(reason:)
    transaction do
      update!(status: "cancelled")
      # delete_all: one statement, no callbacks, every row still audited.
      line_items.delete_all

      AuditLog.notify("order.cancelled", order_id: id, reference: reference, reason: reason)
    end
  end

  private

  def assign_reference
    self.reference ||= "SO-#{Time.current.strftime('%Y%m')}-#{SecureRandom.alphanumeric(6).upcase}"
  end

  def recalculate_total
    self.total_cents = line_items.reject(&:marked_for_destruction?).sum { |i| i.total_cents.to_i }
  end
end
