defmodule Throttler.Schema.Throttle do
  @moduledoc false

  use Ecto.Schema

  schema "throttler_throttles" do
    field :scope, :string
    field :key, :string
    field :last_occurred_at, :utc_datetime_usec
    timestamps()
  end
end
