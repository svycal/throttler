# Throttler

Throttler is a lightweight Elixir DSL for rate-limiting events across arbitrary `scope` and `key` combinations — perfect for throttling notification delivery, message sends, job dispatches, and more.

Backed by Postgres and Ecto, it guarantees **race-safety** using `SELECT FOR UPDATE`, making it ideal for distributed or concurrent systems.

## Features

- ✅ Declarative throttling with a clean DSL
- ✅ Race-safe via Postgres locking
- ✅ Time-window enforcement (e.g., once per hour, max 3 per day)
- ✅ General-purpose: use it for email, SMS, alerts, tasks, etc.
- ✅ Built with plain Ecto — no special dependencies

## Installation

Add to your `mix.exs`:

```elixir
def deps do
  [
    {:throttler, "~> 0.1.0"}
  ]
end
```

## Schema Migrations

Throttler requires two tables to store throttle state and events. You can find a migration template at `priv/repo/migrations/create_throttler_tables.exs.template`.

Create a new migration in your application:

```bash
mix ecto.gen.migration create_throttler_tables
```

Then add the following to your migration:

```elixir
create table(:throttler_throttles) do
  add :scope, :string, null: false
  add :key, :string, null: false
  add :last_sent_at, :utc_datetime_usec
  timestamps()
end

create unique_index(:throttler_throttles, [:scope, :key])

create table(:throttler_events) do
  add :scope, :string, null: false
  add :key, :string, null: false
  add :sent_at, :utc_datetime_usec, null: false
end

create index(:throttler_events, [:scope, :key, :sent_at])
```

## Usage

### 1. Use the DSL in your module:

```elixir
defmodule MyApp.Notifications do
  use Throttler, repo: MyApp.Repo

  def maybe_send(scope) do
    throttle scope, "weekly_digest", max_per: [{1, :hour}, {3, :day}] do
      MyMailer.send_digest(scope)
    end
  end
end
```

### 2. Handle the result:

```elixir
case MyApp.Notifications.maybe_send("user_123") do
  {:ok, :sent} -> :ok
  {:error, :throttled} -> :skip
  {:error, {:exception, e}} -> report_exception(e)
end
```

## Safety

All logic is wrapped in a Postgres transaction and uses `SELECT FOR UPDATE` to prevent race conditions across parallel processes or nodes.

## Formatter Configuration

Throttler exports formatter rules for the `throttle` macro. If you're using Throttler in your project and want parentheses-free formatting, add this to your `.formatter.exs`:

```elixir
[
  import_deps: [:throttler, ...your other deps],
  # ... rest of your formatter config
]
```

This allows you to write:

```elixir
throttle "user_123", "daily_report", max_per: [{1, :day}] do
  send_report()
end
```

## Customization

You can use any string for `scope` and `key`. Examples:

| Use Case          | Scope           | Key                      |
| ----------------- | --------------- | ------------------------ |
| Email throttling  | `"user_123"`    | `"appointment_reminder"` |
| Push notification | `"device:abc"`  | `"low_battery"`          |
| Job dispatch      | `"customer:42"` | `"export:csv"`           |

## Contributing

PRs welcome! This project is small, fast, and designed to be easy to understand.
