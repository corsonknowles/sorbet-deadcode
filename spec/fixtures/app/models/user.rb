# frozen_string_literal: true

class User
  attr_reader :name, :email, :legacy_id

  sig { returns(Company) }
  def company
    Company.find(company_id)
  end

  sig { returns(String) }
  def full_name
    "#{first_name} #{last_name}"
  end

  # Dead: never called anywhere
  def obsolete_export_format
    { name: name, email: email }
  end
end
