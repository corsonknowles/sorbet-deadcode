# frozen_string_literal: true

describe NotificationService do
  it "dispatches welcome" do
    service = NotificationService.new
    expect(service.dispatch("welcome")).to eq("welcome sent")
  end

  it "dispatches reminder via legacy" do
    service = NotificationService.new
    expect(service.legacy_dispatch("reminder")).to eq("reminder sent")
  end
end
