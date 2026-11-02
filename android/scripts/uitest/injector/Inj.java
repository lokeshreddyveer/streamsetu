import android.accessibilityservice.AccessibilityServiceInfo;
import android.app.UiAutomation;
import android.graphics.Rect;
import android.hardware.input.InputManager;
import android.os.HandlerThread;
import android.view.accessibility.AccessibilityNodeInfo;
import android.os.SystemClock;
import android.view.InputDevice;
import android.view.InputEvent;
import android.view.KeyEvent;
import java.io.BufferedReader;
import java.io.InputStreamReader;
import java.lang.reflect.Method;

/**
 * Sends key presses into Android's real input pipeline (the same call the `input` command makes) from one long-lived process, so the gap between two keys is set here on the
 * device and not by how long `adb shell input` takes to start (about a second on a Fire TV Stick). Reads commands from standard input, one per line, and prints what it sent:
 *
 *   tap KEYCODE                          one press and release
 *   seq INTERVAL_MS KEYCODE KEYCODE ...  presses at a fixed interval, scheduled from the first one so they do not drift
 *   hold KEYCODE DURATION_MS PERIOD_MS   a held key: one press, then repeats (repeatCount rising) every PERIOD_MS, then the release
 *   dump                                 the screen as the accessibility tree, in the same XML `uiautomator dump` writes, on one line (read from one connection kept open, so it
 *                                        takes tens of milliseconds, not the two seconds a new `uiautomator dump` process takes)
 *   quit
 *
 * A stress workload: the keys come from the system's injection path, not a remote, so they measure what the app does with a flood of keys, not what a remote feels like.
 */
public class Inj {
    private static InputManager im;
    private static Method inject;

    public static void main(String[] args) throws Exception {
        im = (InputManager) InputManager.class.getDeclaredMethod("getInstance").invoke(null);
        inject = InputManager.class.getMethod("injectInputEvent", InputEvent.class, int.class);
        System.out.println("ready");
        BufferedReader in = new BufferedReader(new InputStreamReader(System.in));
        for (String line; (line = in.readLine()) != null; ) {
            String[] p = line.trim().split("\\s+");
            if (p[0].equals("quit")) break;
            if (p[0].equals("dump")) { System.out.println(dumpScreen()); System.out.println("done dump"); System.out.flush(); continue; }
            if (p[0].equals("tap")) { press(Integer.parseInt(p[1]), true); }
            else if (p[0].equals("seq")) {
                long step = Long.parseLong(p[1]) * 1_000_000L, t0 = System.nanoTime();
                for (int i = 2; i < p.length; i++) {
                    long wait = t0 + (i - 2) * step - System.nanoTime();
                    if (wait > 0) Thread.sleep(wait / 1_000_000L, (int) (wait % 1_000_000L));
                    press(Integer.parseInt(p[i]), true);
                }
            } else if (p[0].equals("hold")) {
                int key = Integer.parseInt(p[1]); long dur = Long.parseLong(p[2]), period = Long.parseLong(p[3]);
                long down = SystemClock.uptimeMillis(), end = down + dur; int n = 0;
                send(key, KeyEvent.ACTION_DOWN, 0, down, down);
                while (SystemClock.uptimeMillis() + period < end) {
                    Thread.sleep(period);
                    send(key, KeyEvent.ACTION_DOWN, ++n, down, SystemClock.uptimeMillis());
                }
                long now = SystemClock.uptimeMillis(); Thread.sleep(Math.max(0, end - now));
                send(key, KeyEvent.ACTION_UP, 0, down, SystemClock.uptimeMillis());
            }
            System.out.println("done " + line.trim());
            System.out.flush();
        }
    }

    private static void press(int key, boolean release) throws Exception {
        long t = SystemClock.uptimeMillis();
        send(key, KeyEvent.ACTION_DOWN, 0, t, t);
        if (release) send(key, KeyEvent.ACTION_UP, 0, t, SystemClock.uptimeMillis());
    }

    private static void send(int key, int action, int repeat, long downTime, long eventTime) throws Exception {
        KeyEvent e = new KeyEvent(downTime, eventTime, action, key, repeat, 0, -1, 0, 0, InputDevice.SOURCE_KEYBOARD);
        inject.invoke(im, e, 0);                      // 0 = do not wait for the app to handle it, so the schedule holds
        if (action == KeyEvent.ACTION_DOWN) System.out.println("sent " + key + " rep=" + repeat + " at=" + eventTime);
    }

    // ---- the screen ------------------------------------------------------------------------------------------------------------------
    private static UiAutomation ui;

    /** One connection to the accessibility system, made the first time and kept (this is what `uiautomator dump` sets up, and throws away, on every call). */
    private static synchronized UiAutomation ui() throws Exception {
        if (ui != null) return ui;
        HandlerThread t = new HandlerThread("ui"); t.start();
        Class<?> iconn = Class.forName("android.app.IUiAutomationConnection");
        Object conn = Class.forName("android.app.UiAutomationConnection").getDeclaredConstructor().newInstance();
        java.lang.reflect.Constructor<?> c = UiAutomation.class.getDeclaredConstructor(android.os.Looper.class, iconn); c.setAccessible(true);
        UiAutomation a = (UiAutomation) c.newInstance(t.getLooper(), conn);
        Method connect = UiAutomation.class.getDeclaredMethod("connect"); connect.setAccessible(true); connect.invoke(a);
        AccessibilityServiceInfo info = a.getServiceInfo();
        info.flags |= AccessibilityServiceInfo.FLAG_REPORT_VIEW_IDS | AccessibilityServiceInfo.FLAG_INCLUDE_NOT_IMPORTANT_VIEWS | AccessibilityServiceInfo.FLAG_RETRIEVE_INTERACTIVE_WINDOWS;
        a.setServiceInfo(info);
        return ui = a;
    }

    private static String dumpScreen() {
        try {
            AccessibilityNodeInfo root = ui().getRootInActiveWindow();
            StringBuilder sb = new StringBuilder("<?xml version='1.0' encoding='UTF-8' standalone='yes' ?><hierarchy rotation=\"0\">");
            if (root != null) write(root, sb, 0);
            return sb.append("</hierarchy>").toString();
        } catch (Throwable e) { return "dump-failed " + e.getClass().getSimpleName() + ": " + String.valueOf(e.getMessage()).replace('\n', ' '); }
    }

    private static void write(AccessibilityNodeInfo n, StringBuilder sb, int index) {
        Rect r = new Rect(); n.getBoundsInScreen(r);
        sb.append("<node index=\"").append(index).append("\" text=\"").append(esc(n.getText())).append("\" resource-id=\"").append(esc(n.getViewIdResourceName()))
          .append("\" class=\"").append(esc(n.getClassName())).append("\" content-desc=\"").append(esc(n.getContentDescription())).append("\" clickable=\"").append(n.isClickable())
          .append("\" focusable=\"").append(n.isFocusable()).append("\" focused=\"").append(n.isFocused()).append("\" selected=\"").append(n.isSelected())
          .append("\" bounds=\"[").append(r.left).append(',').append(r.top).append("][").append(r.right).append(',').append(r.bottom).append("]\">");
        for (int i = 0; i < n.getChildCount(); i++) {
            AccessibilityNodeInfo c = n.getChild(i);
            if (c != null && c.isVisibleToUser()) write(c, sb, i);
        }
        sb.append("</node>");
    }

    private static String esc(CharSequence s) {
        if (s == null) return "";
        StringBuilder b = new StringBuilder(s.length());
        for (int i = 0; i < s.length(); i++) {
            char c = s.charAt(i);
            switch (c) { case '&': b.append("&amp;"); break; case '<': b.append("&lt;"); break; case '>': b.append("&gt;"); break; case '"': b.append("&quot;"); break;
                case '\n': b.append("&#10;"); break; case '\r': b.append("&#13;"); break; case '\t': b.append("&#9;"); break; default: if (c >= 0x20) b.append(c); }
        }
        return b.toString();
    }
}
