# frozen_string_literal: true

class User < ApplicationRecord
  # NO authentication gem and no password at all, deliberately. The audit library
  # never names Devise or anything else -- it asks AuditLog.config.actor_resolver
  # for `current_user`, and a dummy app with no auth gem is what proves that
  # nothing more is required. SessionsController just puts an id in the session.

  ROLES = %w[staff manager auditor].freeze

  has_many :orders, foreign_key: :created_by_id, inverse_of: :created_by, dependent: :nullify

  validates :name, presence: true
  validates :role, inclusion: { in: ROLES }

  # The label the audit log snapshots onto every row this user touches.
  def to_label
    "#{name} <#{email}>"
  end

  def auditor? = role == "auditor"
  def manager? = role.in?(%w[manager auditor])
end
