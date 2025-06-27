defmodule ThrottlerCleanupTest do
  use Throttler.DataCase

  describe "cleanup_old_events/2" do
    test "deletes events older than cutoff time" do
      now = DateTime.utc_now()

      # Insert events at different times
      old_event =
        TestRepo.insert!(%Throttler.Schema.Event{
          scope: "test_scope",
          key: "test_key",
          # 48 hours ago
          sent_at: DateTime.add(now, -48 * 60 * 60, :second)
        })

      recent_event =
        TestRepo.insert!(%Throttler.Schema.Event{
          scope: "test_scope",
          key: "test_key",
          # 12 hours ago
          sent_at: DateTime.add(now, -12 * 60 * 60, :second)
        })

      # Set cutoff to 24 hours ago
      cutoff = DateTime.add(now, -24 * 60 * 60, :second)

      # Clean up old events
      count = Throttler.Policy.cleanup_old_events(TestRepo, cutoff)

      # Should have deleted 1 event (the 48-hour old one)
      assert count == 1

      # Verify the old event is gone and recent event remains
      assert TestRepo.get(Throttler.Schema.Event, old_event.id) == nil
      assert TestRepo.get(Throttler.Schema.Event, recent_event.id) != nil
    end

    test "returns 0 when no events to delete" do
      now = DateTime.utc_now()
      cutoff = DateTime.add(now, -24 * 60 * 60, :second)

      # No events in database
      count = Throttler.Policy.cleanup_old_events(TestRepo, cutoff)
      assert count == 0
    end
  end

  describe "cleanup_old_events/4" do
    test "deletes old events for specific scope and key only" do
      now = DateTime.utc_now()
      old_time = DateTime.add(now, -48 * 60 * 60, :second)
      cutoff = DateTime.add(now, -24 * 60 * 60, :second)

      # Insert events for different scope/key combinations
      target_event =
        TestRepo.insert!(%Throttler.Schema.Event{
          scope: "user_1",
          key: "notification",
          sent_at: old_time
        })

      other_scope_event =
        TestRepo.insert!(%Throttler.Schema.Event{
          scope: "user_2",
          key: "notification",
          sent_at: old_time
        })

      other_key_event =
        TestRepo.insert!(%Throttler.Schema.Event{
          scope: "user_1",
          key: "reminder",
          sent_at: old_time
        })

      # Clean up old events for specific scope/key
      count = Throttler.Policy.cleanup_old_events(TestRepo, "user_1", "notification", cutoff)

      # Should have deleted only 1 event
      assert count == 1

      # Verify only the target event was deleted
      assert TestRepo.get(Throttler.Schema.Event, target_event.id) == nil
      assert TestRepo.get(Throttler.Schema.Event, other_scope_event.id) != nil
      assert TestRepo.get(Throttler.Schema.Event, other_key_event.id) != nil
    end
  end

  describe "calculate_safe_cutoff/1" do
    test "calculates cutoff based on longest time window with buffer" do
      limits = [hour: 2, day: 1]
      cutoff = Throttler.Policy.calculate_safe_cutoff(limits)

      now = DateTime.utc_now()

      # Should be approximately (1 day + 24 hour buffer) = 48 hours ago
      expected_seconds = -(1 * 24 * 60 * 60 + 24 * 60 * 60)
      expected_time = DateTime.add(now, expected_seconds, :second)

      # Allow 5 second tolerance for test execution time
      diff = DateTime.diff(cutoff, expected_time, :second)
      assert abs(diff) <= 5
    end

    test "handles single limit correctly" do
      limits = [hour: 6]
      cutoff = Throttler.Policy.calculate_safe_cutoff(limits)

      now = DateTime.utc_now()

      # Should be approximately (6 hours + 24 hour buffer) = 30 hours ago
      expected_seconds = -(6 * 60 * 60 + 24 * 60 * 60)
      expected_time = DateTime.add(now, expected_seconds, :second)

      # Allow 5 second tolerance
      diff = DateTime.diff(cutoff, expected_time, :second)
      assert abs(diff) <= 5
    end
  end

  describe "Throttler.cleanup_old_events/2" do
    test "cleans up events using keyword options" do
      now = DateTime.utc_now()

      # Insert old event
      old_event =
        TestRepo.insert!(%Throttler.Schema.Event{
          scope: "test",
          key: "test",
          # 8 days ago
          sent_at: DateTime.add(now, -8 * 24 * 60 * 60, :second)
        })

      # Insert recent event
      recent_event =
        TestRepo.insert!(%Throttler.Schema.Event{
          scope: "test",
          key: "test",
          # 3 days ago
          sent_at: DateTime.add(now, -3 * 24 * 60 * 60, :second)
        })

      # Clean up events older than 7 days
      count = Throttler.cleanup_old_events(TestRepo, days: 7)

      # Should have deleted the 8-day old event
      assert count == 1
      assert TestRepo.get(Throttler.Schema.Event, old_event.id) == nil
      assert TestRepo.get(Throttler.Schema.Event, recent_event.id) != nil
    end

    test "uses default of 7 days when no options provided" do
      # This test ensures the default behavior works
      count = Throttler.cleanup_old_events(TestRepo, [])
      # Should not error
      assert count >= 0
    end
  end

  describe "Throttler.calculate_safe_cutoff/1" do
    test "calculates safe cutoff for given limits" do
      limits = [hour: 1, day: 3]
      cutoff = Throttler.calculate_safe_cutoff(limits)

      # Should return a DateTime in the past
      assert DateTime.compare(cutoff, DateTime.utc_now()) == :lt
    end
  end
end
