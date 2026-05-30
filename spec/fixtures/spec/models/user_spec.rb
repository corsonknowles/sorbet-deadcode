# frozen_string_literal: true

describe User do
  it "returns full name" do
    user = User.new
    expect(user.full_name).to eq("John Doe")
  end

  it "has an obsolete export format" do
    user = User.new
    expect(user.obsolete_export_format).to be_a(Hash)
  end
end
