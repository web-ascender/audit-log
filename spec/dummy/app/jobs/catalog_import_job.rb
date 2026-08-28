# frozen_string_literal: true

# The bypass demo, and the only class in AuditLog.config.bypass_allowlist.
#
# A large import is the one case where writing an audit row per record is
# genuinely not wanted. The bypass logs ITSELF first: an un-narrated gap in the
# audit log is a finding, a narrated one is a control.
class CatalogImportJob < ApplicationJob
  queue_as :default

  def perform(rows)
    AuditLog.without_logging(reason: "Bulk catalog import (#{rows.size} rows)", by: self.class) do
      Product.upsert_all(rows, unique_by: :sku, record_timestamps: true)
    end
  end
end
