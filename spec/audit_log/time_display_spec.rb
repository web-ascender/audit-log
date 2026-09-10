# frozen_string_literal: true

require "rails_helper"

# What a timestamp on an audit screen must never do: omit the date, omit the
# zone, or be formatted by a decision the host app made for its own pages.
#
# All three were real. `l(time, format: :short)` read the HOST's
# `time.formats.short`, so an application that had set that to a time-only
# format got audit screens showing no date at all -- and Rails' own default omits
# the year, on a log kept for seven years.
RSpec.describe "timestamp display" do
  include AuditLog::AuditHelper
  include ActionView::Helpers::TagHelper

  # The helper needs these two only for tag(); nothing here renders a template.
  def output_buffer = @output_buffer ||= ActionView::OutputBuffer.new
  attr_writer :output_buffer

  let(:instant) { Time.utc(2026, 9, 10, 13, 6, 15, 123_456) }

  it "names the date, the year and the zone" do
    rendered = audit_time(instant)

    expect(rendered).to include("10 Sep 2026")
    expect(rendered).to include("13:06")
    expect(rendered).to include("UTC")
  end

  # The one that broke a real app. A host's own formatting choice must not reach
  # these screens, in either direction.
  it "ignores the host's time.formats.short entirely" do
    with_translations("time.formats.short" => "%H:%M") do
      expect(audit_time(instant)).to include("10 Sep 2026")
    end

    with_translations("time.formats.short" => "nonsense") do
      expect(audit_time(instant)).not_to include("nonsense")
    end
  end

  # The visible text may be re-rendered in the reader's zone by the browser, so
  # the recorded instant has to survive somewhere that does not change.
  it "carries the exact recorded instant at microsecond precision" do
    rendered = audit_time(instant)

    expect(rendered).to include(%(datetime="2026-09-10T13:06:15.123456Z"))
    expect(rendered).to include(%(title="2026-09-10T13:06:15.123456Z"))
  end

  it "renders a non-UTC input as the UTC instant it stands for" do
    rendered = audit_time(instant.in_time_zone("America/New_York"))

    expect(rendered).to include("13:06").and include("UTC")
  end

  it "renders nothing for a nil timestamp rather than an empty element" do
    expect(audit_time(nil)).to eq("")
  end

  describe "config.display_time_zone" do
    it "marks timestamps for the browser to localise under :viewer" do
      with_display_zone(:viewer) do
        expect(audit_time(instant)).to include(%(data-audit-time="local"))
      end
    end

    # No marker, so the script it pairs with has nothing to convert even if some
    # other screen renders it.
    it "leaves them alone under :utc" do
      with_display_zone(:utc) do
        expect(audit_time(instant)).not_to include("data-audit-time")
      end
    end

    # A typo falling through to UTC for every reader is the silent failure this
    # exists to prevent -- the same posture as verify_correlated_connections!.
    it "refuses to boot on a value that is neither" do
      with_display_zone(:local) do
        expect { AuditLog.config.verify_display_time_zone! }
          .to raise_error(ArgumentError, /:local.*not one of/m)
      end
    end

    it "accepts both real values" do
      %i[viewer utc].each do |zone|
        with_display_zone(zone) do
          expect { AuditLog.config.verify_display_time_zone! }.not_to raise_error
        end
      end
    end
  end

  # A BCP-47 tag and not a format string, deliberately: a strftime string is what
  # this library just stopped taking from the host's I18n, and it can drop the
  # year or the zone label with nothing reporting it. A locale tag cannot express
  # "no year", which is the point.
  describe "config.timestamp_locale" do
    it "defaults to the reader's own locale" do
      expect(AuditLog.config.timestamp_locale).to be_nil
      expect { AuditLog.config.verify_display_time_zone! }.not_to raise_error
    end

    it "accepts a language tag, a region, and the unicode extensions a house style needs" do
      ["en", "en-US", "en-GB", "fr-CA", "en-US-u-hc-h23", "de-DE-u-ca-gregory"].each do |tag|
        with_locale(tag) do
          expect { AuditLog.config.verify_display_time_zone! }.not_to raise_error
        end
      end
    end

    # `en_US` is the typo that matters: Ruby and Rails both spell locales that
    # way, Intl rejects it, and the rejection happens in the reader's browser
    # where nobody is watching.
    it "refuses the underscore spelling, and anything else Intl would throw on" do
      ["en_US", "english", "e", "en--US", "en US"].each do |tag|
        with_locale(tag) do
          expect { AuditLog.config.verify_display_time_zone! }
            .to raise_error(ArgumentError, /BCP-47/), "accepted #{tag.inspect}"
        end
      end
    end

    # It reaches the browser, and the SERVER text is untouched by it -- that
    # fallback is deliberately unambiguous in every locale, month as a name.
    it "changes nothing about the server-rendered timestamp" do
      with_locale("en-US") do
        expect(audit_time(instant)).to include("10 Sep 2026 13:06 UTC")
      end
    end
  end

  def with_locale(tag)
    original = AuditLog.config.timestamp_locale
    AuditLog.config.timestamp_locale = tag
    yield
  ensure
    AuditLog.config.timestamp_locale = original
  end

  def with_display_zone(zone)
    original = AuditLog.config.display_time_zone
    AuditLog.config.display_time_zone = zone
    yield
  ensure
    AuditLog.config.display_time_zone = original
  end

  def with_translations(pairs)
    pairs.each { |key, value| I18n.backend.store_translations(:en, key_hash(key, value)) }
    yield
  ensure
    I18n.backend.reload!
  end

  def key_hash(dotted, value)
    dotted.split(".").reverse.reduce(value) { |acc, part| { part.to_sym => acc } }
  end
end
