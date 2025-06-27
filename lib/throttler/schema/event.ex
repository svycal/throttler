defmodule Throttler.Schema.Event do
  @moduledoc false

  use Ecto.Schema

  schema "throttler_events" do
    field :scope, :string
    field :key, :string
    field :sent_at, :utc_datetime_usec
  end
end
