defmodule Throttler.DataCase do
  use ExUnit.CaseTemplate

  using do
    quote do
      alias Throttler.TestRepo

      import Ecto
      import Ecto.Changeset
      import Ecto.Query
      import Throttler.DataCase
    end
  end

  setup tags do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Throttler.TestRepo)

    unless tags[:async] do
      Ecto.Adapters.SQL.Sandbox.mode(Throttler.TestRepo, {:shared, self()})
    end

    :ok
  end
end
