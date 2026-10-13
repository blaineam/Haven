package android.os;

/** JVM test double: the unit-test android.jar throws "not mocked" from every SystemClock call. */
public final class SystemClock {
    private SystemClock() {}
    public static long uptimeMillis() { return System.nanoTime() / 1_000_000L; }
    public static long elapsedRealtime() { return System.nanoTime() / 1_000_000L; }
    public static long elapsedRealtimeNanos() { return System.nanoTime(); }
    public static long currentThreadTimeMillis() { return 0L; }
}
