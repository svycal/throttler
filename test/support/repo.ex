defmodule Throttler.TestRepo do
  use Ecto.Repo,
    otp_app: :throttler,
    adapter: Ecto.Adapters.Postgres
end
