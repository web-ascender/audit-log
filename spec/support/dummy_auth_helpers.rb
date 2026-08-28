# frozen_string_literal: true

# The dummy app has no authentication gem, so there is no Devise `sign_in` to
# include. This goes through SessionsController for real rather than stubbing
# current_user, because the thing under test is precisely whether the library is
# satisfied by an ordinary controller method.
module DummyAuthHelpers
  def sign_in(user)
    post test_session_path, params: { user_id: user.id }
  end

  def sign_out
    delete test_session_path
  end
end

RSpec.configure do |config|
  config.include DummyAuthHelpers, type: :request
end
