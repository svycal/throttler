defmodule Throttler do
  @moduledoc """
  A lightweight DSL for enforcing general throttling policies, such as controlling
  notification frequency.

  ## Usage

      defmodule MyApp.Notifications do
        use Throttler, repo: MyApp.Repo

        def maybe_send_digest(scope) do
          throttle scope, "digest", max_per: [{1, :hour}, {3, :day}] do
            send_digest_email(scope)
          end
        end
      end
  """

  defmacro __using__(opts) do
    repo = Keyword.fetch!(opts, :repo)

    quote bind_quoted: [repo: repo] do
      import Throttler, only: [throttle: 3, throttle: 4]

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
end
