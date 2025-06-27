defmodule ThrottlerConcurrentTest do
  use Throttler.DataCase, async: false

  defmodule ConcurrentTestModule do
    use Throttler, repo: Throttler.TestRepo

    def send_with_throttle(scope, key, opts) do
      throttle scope, key, opts do
        {:executed, System.system_time(:millisecond)}
      end
    end
  end

  describe "concurrent access" do
    test "handles race condition when creating throttle records" do
      # Spawn multiple processes trying to create the same throttle record
      parent = self()

      tasks =
        for _i <- 1..10 do
          Task.async(fn ->
            result =
              ConcurrentTestModule.send_with_throttle("concurrent_user", "race_test",
                max_per: [{5, :hour}]
              )

            send(parent, {self(), result})
          end)
        end

      # Wait for all tasks
      Task.yield_many(tasks, 5000)

      # Collect results
      results =
        for _ <- 1..10 do
          receive do
            {_pid, result} -> result
          after
            1000 -> nil
          end
        end

      # Filter out nils and count successes vs throttled
      valid_results = Enum.filter(results, & &1)
      success_count = Enum.count(valid_results, fn r -> r == {:ok, :sent} end)
      throttled_count = Enum.count(valid_results, fn r -> r == {:error, :throttled} end)

      # Should have exactly 5 successes (the limit) and 5 throttled
      assert success_count == 5
      assert throttled_count == 5

      # Should have exactly one throttle record
      throttles = TestRepo.all(Throttler.Schema.Throttle)

      matching_throttles =
        Enum.filter(throttles, fn t ->
          t.scope == "concurrent_user" && t.key == "race_test"
        end)

      assert length(matching_throttles) == 1
    end

    test "maintains consistency under concurrent load with same scope/key" do
      # Set a limit of 3 per minute
      opts = [max_per: [{3, :minute}]]
      parent = self()

      # Spawn 20 concurrent attempts
      tasks =
        for _i <- 1..20 do
          Task.async(fn ->
            # Add small random delay to increase contention
            Process.sleep(:rand.uniform(10))
            result = ConcurrentTestModule.send_with_throttle("load_test_user", "load_test", opts)
            send(parent, {self(), result})
          end)
        end

      # Wait for all tasks
      Task.yield_many(tasks, 5000)

      # Collect results
      results =
        for _ <- 1..20 do
          receive do
            {_pid, result} -> result
          after
            1000 -> nil
          end
        end

      valid_results = Enum.filter(results, & &1)
      success_count = Enum.count(valid_results, fn r -> r == {:ok, :sent} end)

      # Should have exactly 3 successes
      assert success_count == 3

      # Verify exactly 3 events were created
      events =
        TestRepo.all(
          from e in Throttler.Schema.Event,
            where: e.scope == "load_test_user" and e.key == "load_test"
        )

      assert length(events) == 3
    end

    test "handles concurrent access across different scopes correctly" do
      opts = [max_per: [{1, :hour}]]
      parent = self()

      # Create 10 different users, each trying twice
      tasks =
        for user_id <- 1..10, attempt <- 1..2 do
          Task.async(fn ->
            scope = "user_#{user_id}"
            result = ConcurrentTestModule.send_with_throttle(scope, "concurrent_event", opts)
            send(parent, {scope, attempt, result})
          end)
        end

      # Wait for all tasks
      Task.yield_many(tasks, 5000)

      # Collect and group results by scope
      results_by_scope =
        for _ <- 1..20 do
          receive do
            {scope, attempt, result} -> {scope, attempt, result}
          after
            1000 -> nil
          end
        end
        |> Enum.filter(& &1)
        |> Enum.group_by(fn {scope, _, _} -> scope end)

      # Each scope should have exactly one success
      Enum.each(results_by_scope, fn {scope, scope_results} ->
        success_count =
          Enum.count(scope_results, fn {_, _, result} ->
            result == {:ok, :sent}
          end)

        assert success_count == 1, "Scope #{scope} should have exactly 1 success"
      end)
    end

    test "transaction isolation prevents double-sending" do
      # This tests that our SELECT FOR UPDATE properly locks the throttle record
      # Allow 2 per hour
      opts = [max_per: [{2, :hour}]]

      # First, create the throttle record with one event
      ConcurrentTestModule.send_with_throttle("isolation_user", "isolation_test", opts)

      parent = self()

      # Now spawn two processes that will try to send concurrently
      # Both will read the throttle state at the same time, but only one should succeed
      task1 =
        Task.async(fn ->
          # Signal that we're ready
          send(parent, {:ready, 1})

          # Wait for both to be ready
          receive do
            :go -> :ok
          after
            5000 -> :timeout
          end

          # Try to send
          result =
            ConcurrentTestModule.send_with_throttle("isolation_user", "isolation_test", opts)

          send(parent, {:done, 1, result})
        end)

      task2 =
        Task.async(fn ->
          # Signal that we're ready
          send(parent, {:ready, 2})

          # Wait for both to be ready
          receive do
            :go -> :ok
          after
            5000 -> :timeout
          end

          # Try to send
          result =
            ConcurrentTestModule.send_with_throttle("isolation_user", "isolation_test", opts)

          send(parent, {:done, 2, result})
        end)

      # Wait for both tasks to be ready
      receive do
        {:ready, 1} -> :ok
      after
        1000 -> flunk("Task 1 didn't start")
      end

      receive do
        {:ready, 2} -> :ok
      after
        1000 -> flunk("Task 2 didn't start")
      end

      # Tell both to proceed
      send(task1.pid, :go)
      send(task2.pid, :go)

      # Collect results
      results =
        for _ <- 1..2 do
          receive do
            {:done, _id, result} -> result
          after
            5000 -> nil
          end
        end
        |> Enum.filter(& &1)

      # One should be throttled, one should succeed
      throttled_count = Enum.count(results, fn r -> r == {:error, :throttled} end)
      success_count = Enum.count(results, fn r -> r == {:ok, :sent} end)

      assert throttled_count == 1, "Expected 1 throttled, got #{throttled_count}"
      assert success_count == 1, "Expected 1 success, got #{success_count}"

      # Clean up
      Task.shutdown(task1, :brutal_kill)
      Task.shutdown(task2, :brutal_kill)
    end
  end
end
