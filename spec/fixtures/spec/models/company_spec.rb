# frozen_string_literal: true

describe Company do
  it "returns display name" do
    company = Company.new
    expect(company.display_name).to eq("ACME")
  end

  it "returns employee count" do
    company = Company.new
    expect(company.employee_count).to eq(42)
  end
end
