# frozen_string_literal: true

class ApplicationController < ActionController::Base
  before_action :authenticate_user!

  # The ENTIRE web-side integration -- one include, and nothing per-controller.
  # It sets the correlation id and the actor identity for the request; the
  # triggers, the event subscriber and any job enqueued downstream all read from
  # there.
  #
  # AFTER authenticate_user!, so current_user is resolved by the time the audit
  # before_action runs.
  include AuditLog::ControllerContext

  # Deliberately hand-rolled, and deliberately trivial. The reference app uses
  # Devise; this one uses a session key and nothing else. Both satisfy the
  # library's ONLY web-side requirement -- that `current_user` answer in
  # controller scope -- which is the point of testing against this app: if a spec
  # here passes, the coupling really is just AuditLog.config.actor_resolver.
  def current_user
    return @current_user if defined?(@current_user)

    @current_user = session[:user_id] && User.find_by(id: session[:user_id])
  end
  helper_method :current_user

  private

  def authenticate_user!
    head :unauthorized unless current_user
  end
end
