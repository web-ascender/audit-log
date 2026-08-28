# frozen_string_literal: true

class Shipment < ApplicationRecord
  belongs_to :order

  scope :pending, -> { where(status: "pending") }
end
