package android.util;

/** JVM test double: the unit-test android.jar throws "not mocked" from every Log call. No-ops. */
public final class Log {
    private Log() {}
    public static int v(String t, String m) { return 0; }
    public static int d(String t, String m) { return 0; }
    public static int i(String t, String m) { return 0; }
    public static int w(String t, String m) { return 0; }
    public static int w(String t, Throwable e) { return 0; }
    public static int w(String t, String m, Throwable e) { return 0; }
    public static int e(String t, String m) { return 0; }
    public static int e(String t, String m, Throwable e) { return 0; }
}
