defmodule ThrottlerTest do
  use Throttler.DataCase

  defmodule TestModule do
    @moduledoc false

    use Throttler, repo: Throttler.TestRepo

    def send_with_throttle(scope, key, opts) do
      throttle scope, key, opts do
        {:executed, System.system_time(:millisecond)}
      end
    end

    def send_with_error(scope, key, opts) do
      throttle scope, key, opts do
        raise "Test error"
      end
    end
  end

  describe "basic throttling" do
    test "allows first execution" do
      result = TestModule.send_with_throttle("user_1", "test_event", max_per: [hour: 1])
      assert {:ok, :sent} = result
    end

    test "throttles second execution within time window" do
      assert {:ok, :sent} =
               TestModule.send_with_throttle("user_2", "test_event", max_per: [hour: 1])

      assert {:error, :throttled} =
               TestModule.send_with_throttle("user_2", "test_event", max_per: [hour: 1])
    end

    test "allows execution after time window expires" do
      now = DateTime.utc_now()
      # 61+ minutes ago
      past_time = DateTime.add(now, -3700, :second)

      # Insert a past event
      TestRepo.insert!(%Throttler.Schema.Event{
        scope: "user_3",
        key: "test_event",
        sent_at: past_time
      })

      # Should allow execution since past the 1 hour window
      assert {:ok, :sent} =
               TestModule.send_with_throttle("user_3", "test_event", max_per: [hour: 1])
    end

    test "tracks throttles per scope and key combination" do
      # Different scopes should not interfere
      assert {:ok, :sent} =
               TestModule.send_with_throttle("user_4", "event_a", max_per: [hour: 1])

      assert {:ok, :sent} =
               TestModule.send_with_throttle("user_5", "event_a", max_per: [hour: 1])

      # Different keys should not interfere
      assert {:ok, :sent} =
               TestModule.send_with_throttle("user_4", "event_b", max_per: [hour: 1])

      # Same scope and key should be throttled
      assert {:error, :throttled} =
               TestModule.send_with_throttle("user_4", "event_a", max_per: [hour: 1])
    end
  end

  describe "multiple time window limits" do
    test "enforces all time window limits" do
      opts = [max_per: [hour: 2, day: 3]]

      # First two should succeed (under both limits)
      assert {:ok, :sent} = TestModule.send_with_throttle("user_6", "multi_limit", opts)
      assert {:ok, :sent} = TestModule.send_with_throttle("user_6", "multi_limit", opts)

      # Third should fail (exceeds hourly limit)
      assert {:error, :throttled} = TestModule.send_with_throttle("user_6", "multi_limit", opts)
    end

    test "respects the most restrictive limit" do
      now = DateTime.utc_now()

      # Insert two events: one 2 hours ago, one 30 minutes ago
      TestRepo.insert!(%Throttler.Schema.Event{
        scope: "user_7",
        key: "multi_limit",
        # 2 hours ago
        sent_at: DateTime.add(now, -7200, :second)
      })

      TestRepo.insert!(%Throttler.Schema.Event{
        scope: "user_7",
        key: "multi_limit",
        # 30 minutes ago
        sent_at: DateTime.add(now, -1800, :second)
      })

      opts = [max_per: [hour: 1, day: 3]]

      # Should be throttled due to hourly limit even though daily limit not reached
      assert {:error, :throttled} = TestModule.send_with_throttle("user_7", "multi_limit", opts)
    end

    test "correctly handles minute-based limits" do
      opts = [max_per: [minute: 2]]

      assert {:ok, :sent} = TestModule.send_with_throttle("user_8", "minute_test", opts)
      assert {:ok, :sent} = TestModule.send_with_throttle("user_8", "minute_test", opts)
      assert {:error, :throttled} = TestModule.send_with_throttle("user_8", "minute_test", opts)
    end
  end

  describe "error handling" do
    test "rolls back transaction on exception in block" do
      # Count events before
      count_before = TestRepo.aggregate(Throttler.Schema.Event, :count)

      # This should return error with exception
      result = TestModule.send_with_error("user_9", "error_test", max_per: [hour: 10])
      assert {:error, {:exception, %RuntimeError{message: "Test error"}}} = result

      # Count should be unchanged
      count_after = TestRepo.aggregate(Throttler.Schema.Event, :count)
      assert count_before == count_after

      # Should be able to try again
      assert {:ok, :sent} =
               TestModule.send_with_throttle("user_9", "error_test", max_per: [hour: 10])
    end

    test "returns exception wrapped in error tuple" do
      result = TestModule.send_with_error("user_10", "error_test", max_per: [hour: 10])
      assert {:error, {:exception, %RuntimeError{message: "Test error"}}} = result
    end
  end

  describe "throttle state management" do
    test "creates throttle record on first use" do
      assert nil == TestRepo.get_by(Throttler.Schema.Throttle, scope: "user_11", key: "new_event")

      TestModule.send_with_throttle("user_11", "new_event", max_per: [hour: 1])

      throttle = TestRepo.get_by(Throttler.Schema.Throttle, scope: "user_11", key: "new_event")
      assert throttle != nil
      assert throttle.scope == "user_11"
      assert throttle.key == "new_event"
      assert throttle.last_sent_at != nil
    end

    test "updates last_sent_at on successful send" do
      # First send
      TestModule.send_with_throttle("user_12", "update_test", max_per: [hour: 10])
      throttle1 = TestRepo.get_by(Throttler.Schema.Throttle, scope: "user_12", key: "update_test")

      # Wait a bit to ensure different timestamp
      Process.sleep(10)

      # Second send
      TestModule.send_with_throttle("user_12", "update_test", max_per: [hour: 10])
      throttle2 = TestRepo.get_by(Throttler.Schema.Throttle, scope: "user_12", key: "update_test")

      assert DateTime.compare(throttle2.last_sent_at, throttle1.last_sent_at) == :gt
    end

    test "does not update last_sent_at when throttled" do
      # First send
      TestModule.send_with_throttle("user_13", "no_update_test", max_per: [hour: 1])

      throttle1 =
        TestRepo.get_by(Throttler.Schema.Throttle, scope: "user_13", key: "no_update_test")

      # Wait a bit
      Process.sleep(10)

      # Second send (should be throttled)
      TestModule.send_with_throttle("user_13", "no_update_test", max_per: [hour: 1])

      throttle2 =
        TestRepo.get_by(Throttler.Schema.Throttle, scope: "user_13", key: "no_update_test")

      assert DateTime.compare(throttle2.last_sent_at, throttle1.last_sent_at) == :eq
    end
  end

  describe "event tracking" do
    test "creates event record on successful send" do
      count_before = TestRepo.aggregate(Throttler.Schema.Event, :count)

      TestModule.send_with_throttle("user_14", "track_test", max_per: [hour: 10])

      count_after = TestRepo.aggregate(Throttler.Schema.Event, :count)
      assert count_after == count_before + 1

      event = TestRepo.get_by(Throttler.Schema.Event, scope: "user_14", key: "track_test")
      assert event != nil
      assert event.sent_at != nil
    end

    test "does not create event when throttled" do
      # First send creates event
      TestModule.send_with_throttle("user_15", "no_track_test", max_per: [hour: 1])
      count1 = TestRepo.aggregate(Throttler.Schema.Event, :count)

      # Second send is throttled, no new event
      TestModule.send_with_throttle("user_15", "no_track_test", max_per: [hour: 1])
      count2 = TestRepo.aggregate(Throttler.Schema.Event, :count)

      assert count2 == count1
    end
  end

  describe "query optimization" do
    test "only fetches events within the oldest time window" do
      now = DateTime.utc_now()

      # Insert events at various times
      events = [
        # 7 days ago (outside window)
        DateTime.add(now, -86_400 * 7, :second),
        # 2 days ago (inside daily window)
        DateTime.add(now, -86_400 * 2, :second),
        # 1 hour ago (inside hourly window)
        DateTime.add(now, -3_600, :second),
        # 30 minutes ago (inside all windows)
        DateTime.add(now, -1_800, :second)
      ]

      Enum.each(events, fn sent_at ->
        TestRepo.insert!(%Throttler.Schema.Event{
          scope: "user_16",
          key: "window_test",
          sent_at: sent_at
        })
      end)

      # With 1 hour and 1 day limits, should only consider last 3 events
      opts = [max_per: [hour: 2, day: 3]]

      # Should succeed (2 events in last hour, limit is 2, so one more is allowed)
      assert {:ok, :sent} = TestModule.send_with_throttle("user_16", "window_test", opts)

      # Now should be throttled (3 events in last hour)
      assert {:error, :throttled} = TestModule.send_with_throttle("user_16", "window_test", opts)
    end
  end
end
