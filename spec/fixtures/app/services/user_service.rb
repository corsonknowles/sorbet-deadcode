# frozen_string_literal: true

class UserService
  sig { params(user: User).returns(String) }
  def format_user(user)
    user.full_name
  end

  sig { params(user: User).returns(Integer) }
  def company_size(user)
    user.company.employee_count
  end

  # Dead: no callers
  def unused_helper
    "not used"
  end
end
