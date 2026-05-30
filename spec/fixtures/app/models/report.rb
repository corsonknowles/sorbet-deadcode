# frozen_string_literal: true

class Report
  sig { returns(String) }
  def generate
    "report data"
  end

  # Same name as Company#display_name — type-aware analysis should
  # distinguish them. If only Company#display_name is called (via
  # typed reference), Report#display_name should be dead.
  sig { returns(String) }
  def display_name
    "Report: #{title}"
  end

  # Dead: never called
  def archive
    "archived"
  end
end
