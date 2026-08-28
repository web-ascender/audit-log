# frozen_string_literal: true

# Note what is NOT in this class: no `has_audit_log`, no `include Auditable`, no
# callback. Field-level change tracking comes from the database trigger attached
# in the migration. That is the whole reason update_all and raw SQL cannot
# escape it.
class Customer < ApplicationRecord
  has_many :orders, dependent: :restrict_with_error

  validates :name, presence: true

  scope :active, -> { where(status: "active") }

  def to_s = name
end
