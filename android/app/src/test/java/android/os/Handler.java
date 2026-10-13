package android.os;

/**
 * JVM test double: the unit-test android.jar throws "not mocked" from the Handler constructor, which
 * made every object holding a main-thread Handler (the QA driver) impossible to load. Work posted
 * here is recorded, never run, so a test decides when "main" gets its turn via {@link #drain()}.
 *
 * Delayed work ({@link #postDelayed}) is kept apart from immediate work: a test that drains "what is
 * due now" must not also fire a 60-second ring timeout that was merely armed. {@link #drainAll()} runs
 * the delayed work too (in the order it was posted), for a test that wants to see the retransmissions.
 */
public class Handler {
    private final java.util.List<Runnable> queue = new java.util.concurrent.CopyOnWriteArrayList<>();
    private final java.util.List<Runnable> delayed = new java.util.concurrent.CopyOnWriteArrayList<>();
    public Handler(Looper looper) {}
    public boolean post(Runnable r) { queue.add(r); return true; }
    public boolean postDelayed(Runnable r, long delayMillis) {
        if (delayMillis <= 0) queue.add(r); else delayed.add(r);
        return true;
    }
    public void removeCallbacks(Runnable r) { queue.remove(r); delayed.remove(r); }
    /** Test hook: run (and clear) the work that is due now. */
    public void drain() {
        java.util.List<Runnable> run = new java.util.ArrayList<>(queue);
        queue.clear();
        for (Runnable r : run) r.run();
    }
    /** Test hook: run everything that is posted, immediate first and then delayed, until nothing is left. */
    public void drainAll() {
        while (!queue.isEmpty() || !delayed.isEmpty()) {
            drain();
            java.util.List<Runnable> later = new java.util.ArrayList<>(delayed);
            delayed.clear();
            for (Runnable r : later) r.run();
        }
    }
    public int pendingCount() { return queue.size() + delayed.size(); }
    public int pendingDelayed() { return delayed.size(); }
}
