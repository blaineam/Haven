package android.util;

/** JVM test double for android.util.Base64 (the unit-test android.jar throws "not mocked"). */
public final class Base64 {
    public static final int DEFAULT = 0, NO_PADDING = 1, NO_WRAP = 2, CRLF = 4, URL_SAFE = 8;
    private Base64() {}

    public static String encodeToString(byte[] in, int flags) {
        java.util.Base64.Encoder e = (flags & URL_SAFE) != 0 ? java.util.Base64.getUrlEncoder() : java.util.Base64.getEncoder();
        if ((flags & NO_PADDING) != 0) e = e.withoutPadding();
        return e.encodeToString(in);
    }

    public static byte[] decode(String s, int flags) {
        java.util.Base64.Decoder d = (flags & URL_SAFE) != 0 ? java.util.Base64.getUrlDecoder() : java.util.Base64.getMimeDecoder();
        return d.decode(s);
    }
}
