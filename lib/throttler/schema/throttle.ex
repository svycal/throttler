defmodule Throttler.Schema.Throttle do
  use Ecto.Schema

  schema "throttler_throttles" do
    field :scope, :string
    field :key, :string
    field :last_sent_at, :utc_datetime_usec
    timestamps()
  end
end
