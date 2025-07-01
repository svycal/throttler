defmodule Throttler do
  @moduledoc """
  A lightweight DSL for enforcing general throttling policies, such as controlling
  notification frequency.

  ## Usage

  You can configure the repo at the module level:

      defmodule MyApp.Notifications do
        use Throttler, repo: MyApp.Repo

        def maybe_send_digest(scope) do
          throttle scope, "digest", max_per: [hour: 1, day: 3] do
            send_digest_email(scope)
          end
        end
      end

  Or configure it globally in your application config:

      # config/config.exs
      config :throttler, repo: MyApp.Repo

  Then use Throttler without specifying the repo:

      defmodule MyApp.Notifications do
        use Throttler

        def maybe_send_digest(scope) do
          throttle scope, "digest", max_per: [hour: 1, day: 3] do
            send_digest_email(scope)
          end
        end
      end
  """

  defmacro __using__(opts) do
    repo = Keyword.get(opts, :repo)

    if repo do
      quote bind_quoted: [repo: repo] do
        import Throttler, only: [throttle: 4]

        defp throttler_repo, do: unquote(repo)
      end
    else
      quote do
        import Throttler, only: [throttle: 4]

        defp throttler_repo, do: Throttler.get_repo()
      end
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
  Returns the globally configured repo for Throttler.

  The repo can be configured in your application config:

      config :throttler, repo: MyApp.Repo

  If no repo is configured, this function will raise an error.
  """
  def get_repo do
    case Application.get_env(:throttler, :repo) do
      nil ->
        raise """
        No repo configured for Throttler.

        Please configure a repo in your config:

            config :throttler, repo: MyApp.Repo

        Or specify it when using Throttler:

            use Throttler, repo: MyApp.Repo
        """

      repo ->
        repo
    end
  end

  @doc """
  Cleans up old throttle events that are no longer needed.

  This function should be called periodically to prevent the throttler_events
  table from growing unbounded. You can run this as a background job or
  scheduled task.

  ## Options

    * `:repo` - The Ecto repo to use. If not provided, uses the globally configured repo.
    * `:days` - Number of days to keep events
    * `:hours` - Number of hours to keep events
    * `:minutes` - Number of minutes to keep events

  ## Examples

      # In a Phoenix application, you might run this daily:
      defmodule MyApp.CleanupJob do
        def perform do
          Throttler.cleanup(days: 7)
        end
      end

      # Clean up events older than specific time periods:
      Throttler.cleanup(days: 30)

      # Clean up events older than a specific time:
      cutoff = DateTime.add(DateTime.utc_now(), -7, :day)
      Throttler.cleanup(cutoff)
  """
  def cleanup(opts) when is_list(opts) do
    {repo, opts} = Keyword.pop(opts, :repo)
    repo = repo || get_repo()
    cutoff = calculate_cutoff_from_opts(opts)
    do_cleanup(repo, cutoff)
  end

  def cleanup(%DateTime{} = cutoff_time) do
    do_cleanup(get_repo(), cutoff_time)
  end

  def cleanup(%DateTime{} = cutoff_time, opts) when is_list(opts) do
    repo = Keyword.get(opts, :repo) || get_repo()
    do_cleanup(repo, cutoff_time)
  end

  defp do_cleanup(repo, %DateTime{} = cutoff_time) do
    import Ecto.Query

    {count, _} =
      from(e in Throttler.Schema.Event, where: e.occurred_at < ^cutoff_time)
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
