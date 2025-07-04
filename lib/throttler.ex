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

  ## Force Option

  You can bypass throttling by passing `force: true`:

      throttle scope, "digest", max_per: [hour: 1], force: true do
        send_digest_email(scope)
      end

  When `force: true` is set, the block will always execute regardless of
  throttle limits. The event will still be recorded for tracking purposes.

  ## DateTime Module Configuration

  You can configure a custom DateTime module for testing purposes:

      # config/test.exs
      config :throttler, date_time_module: MyApp.MockDateTime

  This allows you to mock time-related functions in tests. The module must
  implement `utc_now/0`, `add/3`, and `compare/2` functions compatible with
  Elixir's DateTime module.
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
  Returns the configured DateTime module.

  The DateTime module can be configured in your application config:

      config :throttler, date_time_module: MyApp.MockDateTime

  If no module is configured, defaults to Elixir's DateTime module.
  This is primarily useful for testing with mocked time values.
  """
  def get_date_time_module do
    Application.get_env(:throttler, :date_time_module, DateTime)
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
    date_time_module = get_date_time_module()
    now = date_time_module.utc_now()

    cond do
      days = opts[:days] -> date_time_module.add(now, -days, :day)
      hours = opts[:hours] -> date_time_module.add(now, -hours, :hour)
      minutes = opts[:minutes] -> date_time_module.add(now, -minutes, :minute)
      true -> date_time_module.add(now, -7, :day)
    end
  end
end
