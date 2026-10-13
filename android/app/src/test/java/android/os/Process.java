package android.os;

/** JVM test double: the unit-test android.jar throws "not mocked" from every Process call. */
public final class Process {
    public static final int THREAD_PRIORITY_BACKGROUND = 10;
    public static final int THREAD_PRIORITY_DEFAULT = 0;
    public static final int THREAD_PRIORITY_FOREGROUND = -2;
    public static final int THREAD_PRIORITY_URGENT_AUDIO = -19;
    public static final int THREAD_PRIORITY_AUDIO = -16;
    private Process() {}
    private static final long START = System.nanoTime() / 1_000_000L - 1_000L;
    public static long getStartUptimeMillis() { return START; }
    public static int myPid() { return 4242; }
    public static int myTid() { return 4243; }
    public static int myUid() { return 10_000; }
    public static void setThreadPriority(int priority) {}
    public static void setThreadPriority(int tid, int priority) {}
}
