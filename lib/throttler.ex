defmodule Throttler do
  @moduledoc """
  A lightweight DSL for enforcing general throttling policies, such as controlling
  notification frequency.

  ## Usage

      defmodule MyApp.Notifications do
        use Throttler, repo: MyApp.Repo

        def maybe_send_digest(scope) do
          throttle scope, "digest", max_per: [hour: 1, day: 3] do
            send_digest_email(scope)
          end
        end
      end
  """

  defmacro __using__(opts) do
    repo = Keyword.fetch!(opts, :repo)

    quote bind_quoted: [repo: repo] do
      import Throttler, only: [throttle: 4]

      defp throttler_repo, do: unquote(repo)
    end
  end

  defmacro throttle(scope, key, opts, do: block) do
    quote do
      Throttler.Policy.run(
        throttler_repo(),
        unquote(scope),
        unquote(key),
        unquote(opts),
        fn -> unquote(block) end
      )
    end
  end

  @doc """
  Cleans up old throttle events that are no longer needed.

  This function should be called periodically to prevent the throttler_events 
  table from growing unbounded. You can run this as a background job or 
  scheduled task.

  ## Examples

      # In a Phoenix application, you might run this daily:
      defmodule MyApp.CleanupJob do
        def perform do
          Throttler.cleanup_old_events(MyApp.Repo, days: 7)
        end
      end
      
      # Clean up events older than specific time periods:
      Throttler.cleanup_old_events(MyApp.Repo, days: 30)
      Throttler.cleanup_old_events(MyApp.Repo, hours: 48)
      
      # For more control, calculate safe cutoff based on your limits:
      limits = [hour: 1, day: 3]
      cutoff = Throttler.calculate_safe_cutoff(limits)
      Throttler.cleanup_old_events(MyApp.Repo, cutoff)
  """
  def cleanup_old_events(repo, opts) when is_list(opts) do
    cutoff = calculate_cutoff_from_opts(opts)
    cleanup_old_events(repo, cutoff)
  end

  def cleanup_old_events(repo, cutoff_time) when is_struct(cutoff_time, DateTime) do
    import Ecto.Query
    
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
      Throttler.cleanup_old_events(MyApp.Repo, "user_123", "daily_report", cutoff)
      
  Returns the number of deleted records.
  """
  def cleanup_old_events(repo, scope, key, cutoff_time) do
    import Ecto.Query
    
    {count, _} = 
      from(e in Throttler.Schema.Event, 
           where: e.scope == ^scope and e.key == ^key and e.sent_at < ^cutoff_time)
      |> repo.delete_all()
    
    count
  end

  @doc """
  Calculates a safe cutoff time for cleanup based on configured limits.
  
  Returns a DateTime before which all events can be safely deleted without 
  affecting throttling decisions. Adds a 24-hour buffer for safety.
  
  ## Examples
  
      limits = [hour: 1, day: 3]
      cutoff = Throttler.calculate_safe_cutoff(limits)
      Throttler.cleanup_old_events(MyApp.Repo, cutoff)
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

  defp calculate_cutoff_from_opts(opts) do
    now = DateTime.utc_now()

    cond do
      days = opts[:days] ->
        DateTime.add(now, -days * 24 * 60 * 60, :second)

      hours = opts[:hours] ->
        DateTime.add(now, -hours * 60 * 60, :second)

      minutes = opts[:minutes] ->
        DateTime.add(now, -minutes * 60, :second)

      true ->
        # Default to 7 days if no option provided
        DateTime.add(now, -7 * 24 * 60 * 60, :second)
    end
  end

  defp to_seconds(:minute, n), do: n * 60
  defp to_seconds(:hour, n), do: n * 3_600
  defp to_seconds(:day, n), do: n * 86_400
end
