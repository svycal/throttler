defmodule Throttler.MockDateTime do
  @moduledoc false

  # This module is a mock for testing the configurable date_time_module

  def utc_now do
    # Return a fixed time with microsecond precision for predictable testing
    ~U[2024-01-01 12:00:00.000000Z]
  end

  def add(datetime, amount, unit) do
    DateTime.add(datetime, amount, unit)
  end

  def compare(datetime1, datetime2) do
    DateTime.compare(datetime1, datetime2)
  end
end