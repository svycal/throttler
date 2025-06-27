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
      Enum.map(limits, fn {n, unit} ->
        {n, unit, DateTime.add(now, -(to_seconds(unit, 1) * n), :second)}
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
    Enum.all?(limits, fn {max_count, unit} ->
      cutoff = DateTime.add(now, -to_seconds(unit, 1), :second)
      count = Enum.count(timestamps, &(DateTime.compare(&1, cutoff) == :gt))
      count < max_count
    end)
  end

  defp to_seconds(:minute, n), do: n * 60
  defp to_seconds(:hour, n), do: n * 3_600
  defp to_seconds(:day, n), do: n * 86_400
end
