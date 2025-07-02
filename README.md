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
  add :last_occurred_at, :utc_datetime_usec
  timestamps()
end

create unique_index(:throttler_throttles, [:scope, :key])

create table(:throttler_events) do
  add :scope, :string, null: false
  add :key, :string, null: false
  add :occurred_at, :utc_datetime_usec, null: false
end

create index(:throttler_events, [:scope, :key])
```

## Usage

### 1. Use the DSL in your module:

```elixir
defmodule MyApp.Notifications do
  use Throttler, repo: MyApp.Repo

  def maybe_send(scope) do
    throttle scope, "weekly_digest", max_per: [hour: 1, day: 3] do
      MyMailer.send_digest(scope)
    end
  end
end
```

### 2. Handle the result:

```elixir
case MyApp.Notifications.maybe_send("user:123") do
  {:ok, :sent} -> :ok
  {:error, :throttled} -> :skip
  {:error, {:exception, e}} -> report_exception(e)
end
```

## Global Configuration

You can configure the repo globally in your application config instead of specifying it in each module:

```elixir
# config/config.exs
config :throttler, repo: MyApp.Repo
```

Then use Throttler without specifying the repo:

```elixir
defmodule MyApp.Notifications do
  use Throttler  # No repo: option needed!

  def maybe_send(scope) do
    throttle scope, "weekly_digest", max_per: [hour: 1, day: 3] do
      MyMailer.send_digest(scope)
    end
  end
end
```

The module-level configuration takes precedence over the global configuration if both are provided:

```elixir
# This will use MySpecialRepo, not the globally configured one
defmodule MyApp.SpecialNotifications do
  use Throttler, repo: MySpecialRepo
end
```

## Safety

All logic is wrapped in a Postgres transaction and uses `SELECT FOR UPDATE` to prevent race conditions across parallel processes or nodes.

### ⚠️ Important: Avoid Nested Transactions

The `throttle` block is already wrapped in a database transaction. **Do not use `Repo.transaction` inside the throttle callback**, as nested transactions can produce unexpected results:

```elixir
# ❌ AVOID THIS
throttle "user:123", "notification", max_per: [hour: 1] do
  Repo.transaction(fn ->
    # This creates a nested transaction - don't do this!
    send_notification()
  end)
end

# ✅ DO THIS INSTEAD
throttle "user:123", "notification", max_per: [hour: 1] do
  # Your code runs inside a transaction already
  send_notification()
end
```

If you need to perform additional database operations, they will automatically be part of the same transaction and will be rolled back if an exception occurs.

## Formatter Configuration

Throttler exports formatter rules for the `throttle` macro. If you're using Throttler in your project and want parentheses-free formatting, add this to your `.formatter.exs`:

```elixir
[
  import_deps: [:throttler, ...],
  # ... rest of your formatter config
]
```

This allows you to write:

```elixir
throttle "user:123", "daily_report", max_per: [day: 1] do
  send_report()
end
```

## Configuration

### Time Limits

The `max_per` option accepts a keyword list where keys are time units and values are the maximum number of events allowed in that time period:

```elixir
max_per: [
  minute: 5,    # Max 5 per minute
  hour: 20,     # Max 20 per hour  
  day: 100      # Max 100 per day
]
```

Supported time units: `:minute`, `:hour`, `:day`

The most restrictive limit will be enforced. For example, if you have `[hour: 10, day: 20]` and 10 events have already been sent in the last hour, further attempts will be throttled even if the daily limit hasn't been reached.

### Force Option

You can bypass throttling limits by passing `force: true`. This is useful for critical operations that must execute regardless of throttle limits:

```elixir
# Normal throttling - respects limits
throttle "user:123", "newsletter", max_per: [day: 1] do
  send_newsletter()
end

# Force execution - always runs
throttle "user:123", "newsletter", max_per: [day: 1], force: true do
  send_urgent_security_alert()  # This will always execute
end
```

When `force: true` is set:
- The block will **always execute** regardless of throttle limits
- The event is still recorded in the database for tracking
- The `last_occurred_at` timestamp is updated
- Useful for admin overrides, critical alerts, or testing

```elixir
case MyApp.maybe_notify(user_id, force: admin_override?) do
  {:ok, :sent} -> Logger.info("Notification sent")
  {:error, :throttled} -> Logger.info("Throttled (won't happen with force: true)")
end
```

### Scope and Key

You can use any string for `scope` and `key`. Examples:

| Use Case          | Scope           | Key                      |
| ----------------- | --------------- | ------------------------ |
| Email throttling  | `"user_123"`    | `"appointment_reminder"` |
| Push notification | `"device:abc"`  | `"low_battery"`          |
| Job dispatch      | `"customer:42"` | `"export:csv"`           |

## Event Cleanup

**Important**: The `throttler_events` table will grow over time as events are recorded. You should periodically clean up old events to prevent unbounded growth.

### Automatic Cleanup

Add a background job to clean up old events periodically:

```elixir
# In a Phoenix app with Oban
defmodule MyApp.ThrottlerCleanupJob do
  use Oban.Worker, queue: :maintenance

  @impl Oban.Worker
  def perform(_job) do
    # Clean up events older than 30 days (uses global repo)
    deleted_count = Throttler.cleanup(days: 30)
    {:ok, %{deleted_events: deleted_count}}
  end
end
```

The cleanup function accepts several options:

```elixir
# Use the globally configured repo
Throttler.cleanup(days: 7)
Throttler.cleanup(hours: 48)

# Or specify a repo explicitly
Throttler.cleanup(repo: MyApp.Repo, days: 7)

# Clean up with a specific DateTime cutoff
cutoff = DateTime.add(DateTime.utc_now(), -7, :day)
Throttler.cleanup(cutoff)
```

### Cleanup Strategy

- Events are only needed within the **longest configured time window**
- Cleanup functions return the number of deleted records
- Consider running cleanup daily or weekly depending on your event volume

## Contributing

PRs welcome! This project is small, fast, and designed to be easy to understand.
