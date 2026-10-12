package android.net;

import java.io.ByteArrayOutputStream;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.List;

/**
 * JVM test double for android.net.Uri. The unit-test android.jar throws "not mocked" for every Uri
 * method, which would leave DeepLink's parsers untestable off-device. Test sources sit ahead of that
 * jar on the unit-test classpath, so this shadows it. It implements only the hierarchical-URI parts
 * the app calls, following Android's rules: scheme up to the first ':', authority after "//", path
 * to '?' or '#', fragment after the first '#', path segments and the fragment kept raw until asked.
 */
public class Uri {
    private final String raw, scheme, host, rawPath, rawFragment;

    private Uri(String raw, String scheme, String host, String rawPath, String rawFragment) {
        this.raw = raw; this.scheme = scheme; this.host = host; this.rawPath = rawPath; this.rawFragment = rawFragment;
    }

    public static Uri parse(String s) {
        String rest = s;
        String frag = null;
        int h = rest.indexOf('#');
        if (h >= 0) { frag = rest.substring(h + 1); rest = rest.substring(0, h); }
        int q = rest.indexOf('?');
        if (q >= 0) rest = rest.substring(0, q);
        String scheme = null;
        int colon = rest.indexOf(':');
        int slash = rest.indexOf('/');
        if (colon > 0 && (slash < 0 || colon < slash)) { scheme = rest.substring(0, colon); rest = rest.substring(colon + 1); }
        String host = null, path = rest;
        if (rest.startsWith("//")) {
            int end = rest.indexOf('/', 2);
            String auth = end < 0 ? rest.substring(2) : rest.substring(2, end);
            path = end < 0 ? "" : rest.substring(end);
            int at = auth.lastIndexOf('@'); if (at >= 0) auth = auth.substring(at + 1);
            int pc = auth.lastIndexOf(':'); if (pc >= 0) auth = auth.substring(0, pc);
            host = auth.isEmpty() ? null : auth;
        }
        return new Uri(s, scheme, host, path, frag);
    }

    public String getScheme() { return scheme; }
    public String getHost() { return host; }
    public String getPath() { return decode(rawPath); }
    public String getEncodedFragment() { return rawFragment; }
    public String getFragment() { return rawFragment == null ? null : decode(rawFragment); }

    public List<String> getPathSegments() {
        List<String> out = new ArrayList<>();
        for (String seg : rawPath.split("/")) if (!seg.isEmpty()) out.add(decode(seg));
        return out;
    }

    public static String encode(String s) { return encode(s, null); }

    public static String encode(String s, String allow) {
        StringBuilder b = new StringBuilder();
        for (byte x : s.getBytes(StandardCharsets.UTF_8)) {
            int c = x & 0xFF;
            if ((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || "_-!.~'()*".indexOf(c) >= 0 || (allow != null && allow.indexOf(c) >= 0))
                b.append((char) c);
            else b.append('%').append("0123456789ABCDEF".charAt(c >> 4)).append("0123456789ABCDEF".charAt(c & 15));
        }
        return b.toString();
    }

    public static String decode(String s) {
        if (s == null) return null;
        ByteArrayOutputStream out = new ByteArrayOutputStream();
        byte[] in = s.getBytes(StandardCharsets.UTF_8);
        for (int i = 0; i < in.length; i++) {
            if (in[i] == '%' && i + 2 < in.length && Character.digit(in[i + 1], 16) >= 0 && Character.digit(in[i + 2], 16) >= 0) {
                out.write(Character.digit(in[i + 1], 16) * 16 + Character.digit(in[i + 2], 16)); i += 2;
            } else out.write(in[i]);
        }
        return new String(out.toByteArray(), StandardCharsets.UTF_8);
    }

    @Override public String toString() { return raw; }
}
