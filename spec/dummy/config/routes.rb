# frozen_string_literal: true

Rails.application.routes.draw do
  # The one line a host app adds to get the auditor UI.
  mount AuditLog::Engine => "/audit", as: :audit

  # Test-support only; see SessionsController.
  post   "/test/session" => "sessions#create",  as: :test_session
  delete "/test/session" => "sessions#destroy"
end
