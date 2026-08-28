# frozen_string_literal: true

class Product < ApplicationRecord
  has_many :line_items, dependent: :restrict_with_error

  validates :sku, :name, presence: true
  validates :sku, uniqueness: true
  validates :price_cents, numericality: { greater_than_or_equal_to: 0 }

  scope :active, -> { where(active: true) }

  def price = price_cents / 100.0
  def to_s  = "#{sku} — #{name}"
end
