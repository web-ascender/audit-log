# frozen_string_literal: true

require "rails_helper"

# A shortened request_id has exactly one job: let a human tell two actions apart
# at a glance. Truncating a UUIDv7 from the FRONT cannot do that, and the failure
# is silent -- the page renders, the links work, and two unrelated actions simply
# look like the same one.
RSpec.describe "short request ids" do
  # audit_short_id is pure string work, so it needs no view context.
  let(:helper) { Object.new.extend(AuditLog::AuditHelper) }

  # RFC 9562: bits 0..47 are unix_ts_ms. Eight hex characters is 32 bits, which
  # keeps the top 32 of those 48 and drops the low 16 -- a resolution of 2**16 ms,
  # about 65 seconds. This example documents the trap rather than the fix: if it
  # ever fails, v7 minting changed and the reasoning below needs revisiting.
  it "confirms a front-truncated v7 id collides within the same minute" do
    a = AuditLog::Context.new_request_id
    b = AuditLog::Context.new_request_id

    expect(a).not_to eq(b)
    expect(a.first(8)).to eq(b.first(8))
  end

  it "distinguishes ids minted back to back" do
    ids    = Array.new(50) { AuditLog::Context.new_request_id }
    shorts = ids.map { |i| helper.audit_short_id(i) }

    expect(shorts.uniq.size).to eq(ids.size)
  end

  it "uses the trailing random group, not a prefix" do
    id = "01a0464f-8bb7-74f8-9006-ff7fa8ab4df2"

    expect(helper.audit_short_id(id)).to eq("ff7fa8ab4df2")
    expect(helper.audit_short_id(id)).not_to start_with("01a0464f")
  end
end
