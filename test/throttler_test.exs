defmodule ThrottlerTest do
  use ExUnit.Case
  doctest Throttler

  test "greets the world" do
    assert Throttler.hello() == :world
  end
end
