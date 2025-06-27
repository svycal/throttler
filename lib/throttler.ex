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
    Throttler.Policy.cleanup_old_events(repo, cutoff)
  end

  def cleanup_old_events(repo, cutoff_time) when is_struct(cutoff_time, DateTime) do
    Throttler.Policy.cleanup_old_events(repo, cutoff_time)
  end

  @doc """
  Calculates a safe cutoff time for cleanup based on configured limits.

  See `Throttler.Policy.calculate_safe_cutoff/1` for more details.
  """
  def calculate_safe_cutoff(limits) do
    Throttler.Policy.calculate_safe_cutoff(limits)
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
end
