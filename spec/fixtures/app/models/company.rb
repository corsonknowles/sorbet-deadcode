# frozen_string_literal: true

class Company
  attr_reader :name, :industry

  sig { returns(String) }
  def display_name
    name.upcase
  end

  # Dead: was used in a removed feature
  def old_billing_plan
    "legacy"
  end

  # Alive: called from UserService
  sig { returns(Integer) }
  def employee_count
    42
  end
end
