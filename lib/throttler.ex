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

      # Clean up events older than a specific time:
      cutoff = DateTime.add(DateTime.utc_now(), -7, :day)
      Throttler.cleanup_old_events(MyApp.Repo, cutoff)
  """
  def cleanup_old_events(repo, opts) when is_list(opts) do
    cutoff = calculate_cutoff_from_opts(opts)
    cleanup_old_events(repo, cutoff)
  end

  def cleanup_old_events(repo, %DateTime{} = cutoff_time) do
    import Ecto.Query

    {count, _} =
      from(e in Throttler.Schema.Event, where: e.sent_at < ^cutoff_time)
      |> repo.delete_all()

    count
  end

  defp calculate_cutoff_from_opts(opts) do
    now = DateTime.utc_now()

    cond do
      days = opts[:days] -> DateTime.add(now, -days, :day)
      hours = opts[:hours] -> DateTime.add(now, -hours, :hour)
      minutes = opts[:minutes] -> DateTime.add(now, -minutes, :minute)
      true -> DateTime.add(now, -7, :day)
    end
  end
end
