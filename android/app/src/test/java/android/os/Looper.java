package android.os;

/**
 * JVM test double: the unit-test android.jar throws "not mocked" from {@code Looper.myLooper()}. A
 * test thread is never the main thread, so {@code myLooper()} is null and {@code getMainLooper()}
 * is a distinct sentinel — exactly what {@code HavenNet.onMainThread()} compares.
 *
 * Compose's runtime reads {@code Looper.getMainLooper().getThread()} in a static initializer and
 * only tolerates a RuntimeException there, so every method it (or the app) calls must exist.
 */
public final class Looper {
    private static final Looper MAIN = new Looper();
    /** Never started: its id matches no running thread, so nothing is ever "on main". */
    private final Thread thread = new Thread("test-main-looper");
    private Looper() {}
    public static Looper getMainLooper() { return MAIN; }
    public static Looper myLooper() { return null; }
    public Thread getThread() { return thread; }
    public boolean isCurrentThread() { return Thread.currentThread() == thread; }
}
