# frozen_string_literal: true

describe UserService do
  it "formats user" do
    service = UserService.new
    expect(service.format_user(user)).to eq("John Doe")
  end

  it "returns company size" do
    service = UserService.new
    expect(service.company_size(user)).to eq(42)
  end
end
