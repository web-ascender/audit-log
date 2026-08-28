# frozen_string_literal: true

class LineItem < ApplicationRecord
  belongs_to :order
  belongs_to :product

  validates :quantity, numericality: { greater_than: 0 }

  before_validation :copy_price_from_product, on: :create

  def total_cents = quantity * unit_price_cents

  # The audit log's preferred label hook (AuditLog::RecordLabel), and a good
  # illustration of why that hook exists: a line item has no name, no title and no
  # display `to_s`, so there is no column a library could have inferred a label
  # from. Without this, every line item in the audit UI reads "LineItem #86" --
  # correct, and meaningless. With it, the id keeps a caption beside it.
  def to_audit_label = "#{quantity} × #{description.presence || "item"}"

  private

  def copy_price_from_product
    self.unit_price_cents = product.price_cents if unit_price_cents.to_i.zero? && product
    self.description ||= product&.name
  end
end
