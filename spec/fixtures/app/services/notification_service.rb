# frozen_string_literal: true

class NotificationService
  # This method is called via public_send
  def send_welcome
    "welcome sent"
  end

  # This method is called via send
  def send_reminder
    "reminder sent"
  end

  # Dead: never dispatched
  def send_deprecated_alert
    "deprecated"
  end

  def dispatch(type)
    public_send(:"send_#{type}")
  end

  def legacy_dispatch(type)
    send(:"send_#{type}")
  end
end
