defmodule Throttler.Policy do
  @moduledoc false

  import Ecto.Query

  def run(repo, scope, key, opts, fun) do
    force = Keyword.get(opts, :force, false)

    if force do
      # When force is true, always execute the function
      run_with_transaction(repo, fn -> execute_forced(repo, scope, key, fun) end)
    else
      # Normal throttling behavior
      max_per = Keyword.fetch!(opts, :max_per)
      run_with_transaction(repo, fn -> run_throttle_check(repo, scope, key, max_per, fun) end)
    end
  end

  defp run_with_transaction(repo, transaction_fun) do
    case repo.transaction(transaction_fun) do
      {:ok, result} -> result
      {:error, reason} -> {:error, reason}
    end
  end

  defp execute_forced(repo, scope, key, fun) do
    # Get or create throttle record
    _throttle = get_or_create_throttle!(repo, scope, key)

    # Get the throttle with a lock to ensure proper ID is loaded
    throttle = from(t in throttle_query(scope, key), lock: "FOR UPDATE") |> repo.one!()

    # Execute and record the event
    date_time_module = Throttler.get_date_time_module()
    now = date_time_module.utc_now()
    execute_and_record(repo, scope, key, throttle, now, fun)
  end

  defp run_throttle_check(repo, scope, key, max_per, fun) do
    _throttle = get_or_create_throttle!(repo, scope, key)

    throttle = from(t in throttle_query(scope, key), lock: "FOR UPDATE") |> repo.one!()

    date_time_module = Throttler.get_date_time_module()
    now = date_time_module.utc_now()
    recent = fetch_recent_events(repo, scope, key, max_per)

    if allowed_to_execute?(now, recent, max_per, date_time_module) do
      execute_and_record(repo, scope, key, throttle, now, fun)
    else
      repo.rollback(:throttled)
    end
  end

  defp execute_and_record(repo, scope, key, throttle, now, fun) do
    repo.insert!(%Throttler.Schema.Event{
      scope: scope,
      key: key,
      occurred_at: now
    })

    repo.update!(Ecto.Changeset.change(throttle, last_occurred_at: now))

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
             last_occurred_at: nil
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
    date_time_module = Throttler.get_date_time_module()
    now = date_time_module.utc_now()

    windows =
      Enum.map(limits, fn {unit, n} ->
        {unit, n, date_time_module.add(now, -(to_seconds(unit, 1) * n), :second)}
      end)

    oldest_cutoff =
      windows
      |> Enum.map(fn {_, _, cutoff} -> cutoff end)
      |> Enum.min(date_time_module)

    from(e in Throttler.Schema.Event,
      where: e.scope == ^scope and e.key == ^key,
      where: e.occurred_at > ^oldest_cutoff,
      select: e.occurred_at
    )
    |> repo.all()
  end

  defp allowed_to_execute?(now, timestamps, limits, date_time_module) do
    Enum.all?(limits, fn {unit, max_count} ->
      cutoff = date_time_module.add(now, -to_seconds(unit, 1), :second)
      count = Enum.count(timestamps, &(date_time_module.compare(&1, cutoff) == :gt))
      count < max_count
    end)
  end

  defp to_seconds(:minute, n), do: n * 60
  defp to_seconds(:hour, n), do: n * 3_600
  defp to_seconds(:day, n), do: n * 86_400
end
