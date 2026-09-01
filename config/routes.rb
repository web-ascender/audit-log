# frozen_string_literal: true

AuditLog::Engine.routes.draw do
  root to: "dashboard#show"

  resources :actors, only: %i[index show]
  resources :records, only: %i[index show]
  get "records/:record_type/:record_id/history", to: "records#history", as: :record_history
  resources :actions, only: %i[index show], constraints: { id: %r{[^/]+} }
  resources :requests, only: :show
  resources :out_of_band, only: :index, path: "out-of-band"

  # Q4, the faceted feed. Routed unconditionally even though the nav link is
  # hidden when config.dimension_filters is empty: a route that appears and
  # disappears with a config value is a 404 nobody can debug, and the screen
  # explains itself when there is nothing configured.
  resources :dimensions, only: :index
end
