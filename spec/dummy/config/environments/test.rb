# frozen_string_literal: true

Rails.application.configure do
  config.cache_classes = false
  config.eager_load = false
  config.active_support.deprecation = :stderr
  # :rescuable, not :none. The authorize hook raises ActionController::RoutingError
  # and the screens are SUPPOSED to render that as a 404 -- the existence of an
  # audit console is not something to advertise to someone who cannot use it. With
  # :none the exception escapes the request and the specs asserting 404 cannot run.
  config.action_dispatch.show_exceptions = :rescuable
  config.active_record.migration_error = :page_load
  config.active_record.verbose_query_logs = false

  # db/structure.sql is git-ignored for this disposable app, so re-dumping it after
  # every migration achieves nothing -- and with schema_format = :sql it shells out
  # to pg_dump, which REFUSES to dump a server newer than itself. On a CI runner
  # whose client is PostgreSQL 16 and whose service container is 18, that is a
  # failed build for no reason at all. The reference app, whose structure.sql is
  # committed and reviewed, leaves this on.
  config.active_record.dump_schema_after_migration = false
end
