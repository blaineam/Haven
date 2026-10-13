package android.os;

/**
 * JVM test double: the unit-test android.jar throws "not mocked" from the Handler constructor, which
 * made every object holding a main-thread Handler (the QA driver) impossible to load. Work posted
 * here is recorded, never run, so a test decides when "main" gets its turn via {@link #drain()}.
 */
public class Handler {
    private final java.util.List<Runnable> queue = new java.util.concurrent.CopyOnWriteArrayList<>();
    public Handler(Looper looper) {}
    public boolean post(Runnable r) { queue.add(r); return true; }
    public boolean postDelayed(Runnable r, long delayMillis) { queue.add(r); return true; }
    public void removeCallbacks(Runnable r) { queue.remove(r); }
    /** Test hook: run (and clear) whatever was posted. */
    public void drain() {
        java.util.List<Runnable> run = new java.util.ArrayList<>(queue);
        queue.clear();
        for (Runnable r : run) r.run();
    }
    public int pendingCount() { return queue.size(); }
}
