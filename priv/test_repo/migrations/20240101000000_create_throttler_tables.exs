defmodule Throttler.TestRepo.Migrations.CreateThrottlerTables do
  use Ecto.Migration

  def change do
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
  end
end
