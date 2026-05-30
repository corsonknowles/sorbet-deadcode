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

  # Not statically dead: dispatch/legacy_dispatch build the method name as
  # :"send_#{type}", so any send_* method may be reached at runtime. The
  # interpolated-dispatch detector keeps the whole send_* family alive.
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
