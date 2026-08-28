# frozen_string_literal: true

# Shared examples a host application can use instead of copying a spec file.
#
#   # spec/audit_log/coverage_spec.rb
#   require "rails_helper"
#   require "audit_log/rspec"
#
#   RSpec.describe "audit trigger coverage" do
#     it_behaves_like "an app with complete audit coverage"
#   end
#
# `rails generate audit_log:install` writes exactly that. This exists because the
# install instructions used to say "copy spec/audit_log/coverage_spec.rb", and a
# copied forcing function drifts from the library that defines what it enforces.
#
# Not required by lib/audit_log.rb: rspec-core is a host app's test dependency,
# not this gem's runtime dependency.

RSpec.shared_examples "an app with complete audit coverage" do
  # Override in the host app if the audited tables live on a connection other
  # than the primary one.
  let(:audit_coverage) { AuditLog::Coverage.new }

  it "audits every table that has not been explicitly exempted" do
    expect(audit_coverage.missing).to be_empty, <<~MSG
      Untracked tables: #{audit_coverage.missing.join(", ")}

      Every table is either audited or exempted, with no third option. Either:
        * add `attach_audit_trigger :table, model: "Model"` in a migration
          (`rails generate audit_log:trigger table` writes one), or
        * add the table to AuditLog.config.unaudited_tables with a written reason.

      Do not weaken this spec to make a build pass. It is the only thing standing
      between "we audit everything" and "we audit whatever someone remembered".
    MSG
  end

  # A stale exemption is not cosmetic: it silently re-exempts a NEW table that
  # later reuses the name.
  it "does not exempt a table that no longer exists" do
    expect(audit_coverage.stale_exemptions).to be_empty,
      "Exempted but nonexistent: #{audit_coverage.stale_exemptions.join(", ")}"
  end

  it "records a reason for every exemption" do
    expect(audit_coverage.unreasoned_exemptions).to be_empty,
      "Exempted with no reason: #{audit_coverage.unreasoned_exemptions.join(", ")}"
  end

  it "does not audit the audit tables themselves" do
    expect(audit_coverage).not_to be_audits_the_audit_tables
  end
end
