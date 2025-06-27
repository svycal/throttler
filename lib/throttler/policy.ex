defmodule Throttler.Policy do
  @moduledoc false

  import Ecto.Query

  def run(repo, scope, key, opts, fun) do
    max_per = Keyword.fetch!(opts, :max_per)

    case repo.transaction(fn -> run_throttle_check(repo, scope, key, max_per, fun) end) do
      {:ok, result} -> result
      {:error, reason} -> {:error, reason}
    end
  end

  defp run_throttle_check(repo, scope, key, max_per, fun) do
    _throttle = get_or_create_throttle!(repo, scope, key)

    throttle = from(t in throttle_query(scope, key), lock: "FOR UPDATE") |> repo.one!()

    now = DateTime.utc_now()
    recent = fetch_recent_events(repo, scope, key, max_per)

    if allowed_to_send?(now, recent, max_per) do
      execute_and_record(repo, scope, key, throttle, now, fun)
    else
      repo.rollback(:throttled)
    end
  end

  defp execute_and_record(repo, scope, key, throttle, now, fun) do
    repo.insert!(%Throttler.Schema.Event{
      scope: scope,
      key: key,
      sent_at: now
    })

    repo.update!(Ecto.Changeset.change(throttle, last_sent_at: now))

    try do
      fun.()
      {:ok, :sent}
    rescue
      e -> repo.rollback({:exception, e})
    end
  end

  defp get_or_create_throttle!(repo, scope, key) do
    case repo.insert(
           %Throttler.Schema.Throttle{
             scope: scope,
             key: key,
             last_sent_at: nil
           },
           on_conflict: :nothing,
           conflict_target: [:scope, :key],
           returning: true
         ) do
      {:ok, throttle} -> throttle
      {:error, _} -> throttle_query(scope, key) |> repo.one!()
    end
  end

  defp throttle_query(scope, key) do
    from(t in Throttler.Schema.Throttle,
      where: t.scope == ^scope and t.key == ^key
    )
  end

  defp fetch_recent_events(repo, scope, key, limits) do
    now = DateTime.utc_now()

    windows =
      Enum.map(limits, fn {unit, n} ->
        {unit, n, DateTime.add(now, -(to_seconds(unit, 1) * n), :second)}
      end)

    oldest_cutoff =
      windows
      |> Enum.map(fn {_, _, cutoff} -> cutoff end)
      |> Enum.min(DateTime)

    from(e in Throttler.Schema.Event,
      where: e.scope == ^scope and e.key == ^key,
      where: e.sent_at > ^oldest_cutoff,
      select: e.sent_at
    )
    |> repo.all()
  end

  defp allowed_to_send?(now, timestamps, limits) do
    Enum.all?(limits, fn {unit, max_count} ->
      cutoff = DateTime.add(now, -to_seconds(unit, 1), :second)
      count = Enum.count(timestamps, &(DateTime.compare(&1, cutoff) == :gt))
      count < max_count
    end)
  end

  defp to_seconds(:minute, n), do: n * 60
  defp to_seconds(:hour, n), do: n * 3_600
  defp to_seconds(:day, n), do: n * 86_400

  @doc """
  Cleans up old events that are no longer needed for throttling decisions.

  Deletes all events older than the specified cutoff time across all scopes and keys.

  ## Examples

      # Clean up events older than 7 days
      cutoff = DateTime.add(DateTime.utc_now(), -7 * 24 * 60 * 60, :second)
      Throttler.Policy.cleanup_old_events(MyApp.Repo, cutoff)
      
  Returns the number of deleted records.
  """
  def cleanup_old_events(repo, cutoff_time) do
    {count, _} =
      from(e in Throttler.Schema.Event, where: e.sent_at < ^cutoff_time)
      |> repo.delete_all()

    count
  end

  @doc """
  Cleans up old events for a specific scope and key combination.

  Deletes events older than the specified cutoff time for the given scope/key.
  Useful for targeted cleanup when you know specific throttles are no longer needed.

  ## Examples

      # Clean up old events for a specific user's notifications
      cutoff = DateTime.add(DateTime.utc_now(), -7 * 24 * 60 * 60, :second)
      Throttler.Policy.cleanup_old_events(MyApp.Repo, "user_123", "daily_report", cutoff)
      
  Returns the number of deleted records.
  """
  def cleanup_old_events(repo, scope, key, cutoff_time) do
    {count, _} =
      from(e in Throttler.Schema.Event,
        where: e.scope == ^scope and e.key == ^key and e.sent_at < ^cutoff_time
      )
      |> repo.delete_all()

    count
  end

  @doc """
  Calculates a safe cutoff time based on configured time limits.

  Returns a DateTime before which all events can be safely deleted without 
  affecting throttling decisions. Adds a 24-hour buffer for safety.

  ## Examples

      limits = [hour: 1, day: 3]
      cutoff = Throttler.Policy.calculate_safe_cutoff(limits)
      Throttler.Policy.cleanup_old_events(MyApp.Repo, cutoff)
  """
  def calculate_safe_cutoff(limits) do
    now = DateTime.utc_now()

    # Find the longest time window and add a 24-hour buffer
    longest_seconds =
      limits
      |> Enum.map(fn {unit, n} -> to_seconds(unit, 1) * n end)
      |> Enum.max()

    # Add 24-hour buffer (86400 seconds) for safety
    buffer_seconds = longest_seconds + 86_400

    DateTime.add(now, -buffer_seconds, :second)
  end
end
