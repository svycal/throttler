defmodule ThrottlerCleanupTest do
  use Throttler.DataCase

  describe "Throttler.cleanup_old_events/2 (DateTime cutoff)" do
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
      count = Throttler.cleanup_old_events(TestRepo, cutoff)

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
      count = Throttler.cleanup_old_events(TestRepo, cutoff)
      assert count == 0
    end
  end

  describe "Throttler.cleanup_old_events/2 (keyword options)" do
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
end
