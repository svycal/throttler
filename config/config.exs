import Config

if Mix.env() == :test do
  config :throttler, Throttler.TestRepo,
    username: "postgres",
    password: "postgres",
    database: "throttler_test",
    hostname: "localhost",
    pool: Ecto.Adapters.SQL.Sandbox,
    priv: "priv/test_repo"

  config :throttler, ecto_repos: [Throttler.TestRepo]

  config :logger, level: :warning
end
