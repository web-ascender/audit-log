# frozen_string_literal: true

AuditLog::Engine.routes.draw do
  root to: "dashboard#show"

  resources :actors, only: %i[index show]
  resources :records, only: %i[index show]
  get "records/:record_type/:record_id/history", to: "records#history", as: :record_history
  resources :actions, only: %i[index show], constraints: { id: %r{[^/]+} }
  resources :requests, only: :show
  resources :out_of_band, only: :index, path: "out-of-band"
end
