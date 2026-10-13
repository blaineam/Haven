package android.os;

/**
 * JVM test double: the unit-test android.jar throws "not mocked" from {@code HandlerThread.run}, on a
 * thread nobody joins, so loading anything that owns one (the call manager) left an uncaught exception
 * behind and poisoned whichever coroutine test ran next. This one never starts a thread; work posted
 * to its handler is recorded, not run.
 */
public class HandlerThread extends Thread {
    public HandlerThread(String name) { super(name); }
    @Override public synchronized void start() { /* never runs */ }
    public Looper getLooper() { return Looper.getMainLooper(); }
    public boolean quit() { return true; }
    public boolean quitSafely() { return true; }
}
