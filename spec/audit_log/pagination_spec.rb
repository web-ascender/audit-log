# frozen_string_literal: true

require "rails_helper"

# DESIGN §11.0 Rule 2. The property that matters is not speed, it is that paging
# an audit screen never loses a row: an auditor who pages to the end must have
# seen everything in the range, and must be told when they have.
RSpec.describe AuditLog::Pagination do
  # A bare object rather than a controller, so these assert the pagination
  # itself and not Rails' request plumbing -- which the request specs cover.
  def paginator(page = nil, limit: 3)
    Class.new do
      include AuditLog::Pagination
      define_method(:params) { { page: page } }
    end.new.paginate(scope, limit: limit)
  end

  let(:range) { Time.zone.today.all_day }
  let(:scope) { AuditLog::Change.for_type("Product").occurred_between(range).newest_first }

  before do
    actor = create_user
    as_actor(actor) { 10.times { create_product } }
  end

  # Page through to exhaustion and compare against the unpaginated truth. This
  # is the assertion the fixed row caps could never have passed.
  it "yields every row in the range across pages, exactly once" do
    expected = scope.pluck(:id)
    expect(expected.size).to be > 3

    seen   = []
    cursor = nil
    20.times do
      page = paginator(cursor)
      seen.concat(page.records.map(&:id))
      cursor = page.next
      break if cursor.nil?
    end

    expect(seen).to eq(expected)
    expect(seen.uniq.size).to eq(seen.size)
  end

  # The screen renders "End of results." off this, which is the honest form of
  # what a fixed row cap could only imply.
  it "has no next cursor on the last page" do
    last = nil
    cursor = nil
    20.times do
      last = paginator(cursor)
      cursor = last.next
      break if cursor.nil?
    end
    expect(last.next).to be_nil
  end

  # Rule 1 bought partition pruning with a date predicate. Rule 2 must not spend
  # it: the keyset comparison is ANDed onto the range, never substituted for it.
  it "keeps the screen's date range in the query, so partitions still prune" do
    cursor = paginator.next
    sql    = nil

    ActiveSupport::Notifications.subscribed(->(*, payload) {
      sql ||= payload[:sql] if payload[:sql]&.include?("audit_changes")
    }, "sql.active_record") { paginator(cursor).records }

    expect(sql).to include("occurred_at")
    expect(sql).to match(/BETWEEN|>=/)
  end

  # The bug this caught, made deterministic.
  #
  # The cursor is built with to_json, and ActiveSupport renders a Time at
  # time_precision 3 -- milliseconds. occurred_at is clock_timestamp(), i.e.
  # microseconds. A truncated cursor names an instant slightly EARLIER than the
  # row it came from, so the next page's `occurred_at < cursor` skips everything
  # in the gap and rows vanish between pages.
  #
  # These six rows share a millisecond and differ only in microseconds, so every
  # page boundary lands inside the window the truncation would swallow. Against
  # the default serializer this returns 2 rows instead of 6.
  describe "rows inside one millisecond" do
    let(:scope) { AuditLog::Change.for_type("Tick").newest_first }

    before do
      conn = ActiveRecord::Base.connection
      (1..6).each do |micro|
        conn.execute(<<~SQL)
          INSERT INTO audit_changes
            (occurred_at, record_type, record_id, operation, diff, changed_columns)
          VALUES ('#{Time.now.utc.strftime("%Y-%m-%d")} 12:00:00.50000#{micro}+00',
                  'Tick', #{micro}, 'U', '{}', '{}')
        SQL
      end
    end

    it "pages through all of them without dropping any" do
      seen   = []
      cursor = nil
      10.times do
        page = paginator(cursor, limit: 2)
        seen.concat(page.records.map(&:record_id))
        cursor = page.next
        break if cursor.nil?
      end

      expect(seen).to eq([6, 5, 4, 3, 2, 1])
    end

    it "mints a cursor carrying microseconds, not milliseconds" do
      token = JSON.parse(described_class::Cursor.decode(paginator(nil, limit: 2).next))
      expect(token["occurred_at"]).to match(/\.\d{6}/)
    end
  end

  # The reason this module is hand-rolled rather than Pagy::Keyset. Bundler
  # resolves one pagy per app, and the version window this module could honestly
  # have declared was two releases wide -- so the constraint would have landed in
  # every adopter's own pagination. A dependency added back here would not fail
  # anything else in this suite; it would fail an app six months from now.
  it "brings no pagination dependency into the host app" do
    spec = Gem::Specification.load(File.expand_path("../../audit_log.gemspec", __dir__))

    expect(spec.dependencies.map(&:name)).not_to include("pagy", "kaminari")
    expect(defined?(Pagy)).to be_nil
  end

  describe "a cursor that does not belong to this screen" do
    # A cursor is meaningless outside the ordering it was minted from, so
    # Pagination raises rather than guessing. Silently applying it would drop
    # rows off an audit screen; the only safe recovery is to start over --
    # visibly, at the newest row.
    it "falls back to the first page rather than raising" do
      foreign = described_class::Page.new(AuditLog::Change.order(:record_type, :id), limit: 3).next

      expect { paginator(foreign) }.not_to raise_error
      expect(paginator(foreign).records.map(&:id)).to eq(paginator.records.map(&:id))
    end

    it "falls back on a hand-edited cursor" do
      expect(paginator("not-a-real-cursor").records.map(&:id)).to eq(paginator.records.map(&:id))
    end
  end
end
