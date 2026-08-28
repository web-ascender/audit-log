# frozen_string_literal: true

# The dummy app's whole authentication story, so request specs can sign in
# without an auth gem. Not a model of anything -- it exists because a request
# spec cannot set `session` directly, and going through a real round trip is more
# faithful than stubbing current_user would be.
class SessionsController < ApplicationController
  skip_before_action :authenticate_user!

  def create
    session[:user_id] = params[:user_id]
    head :no_content
  end

  def destroy
    reset_session
    head :no_content
  end
end
