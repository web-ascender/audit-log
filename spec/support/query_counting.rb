# frozen_string_literal: true

# Counting the queries a screen would actually issue.
#
# Shared because two specs assert the same property from opposite ends -- that a
# label warmed for the whole unit of work is a label every value object on the
# page reads for free -- and two copies of the subscriber is how one of them
# comes to filter SCHEMA out and the other not, so the same page "issues" a
# different number of queries in each.
#
# Independent of the ActiveRecord query cache: every count taken through this is
# of primary-key lookups the cache would collapse identically. See the note in
# CLAUDE.md about RSpec running with the cache OFF while requests run with it ON
# -- an assertion that only holds in one of the two is not an assertion.
module QueryCounting
  def count_queries
    count = 0
    sub = ActiveSupport::Notifications.subscribe("sql.active_record") do |_, _, _, _, payload|
      count += 1 unless payload[:name].to_s.match?(/SCHEMA|TRANSACTION/)
    end
    yield
    count
  ensure
    ActiveSupport::Notifications.unsubscribe(sub)
  end
end
