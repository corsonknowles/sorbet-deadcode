# frozen_string_literal: true

describe Report do
  it "generates report" do
    report = Report.new
    expect(report.generate).to eq("report data")
  end
end
