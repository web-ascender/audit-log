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
end
