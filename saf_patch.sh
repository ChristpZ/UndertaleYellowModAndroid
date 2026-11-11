#!/usr/bin/env bash
# saf_patch.sh  -  Añade selector de archivos del sistema al menú Exportar/Importar
#
# Uso:   bash saf_patch.sh entrada.apk salida.apk
# Firma: si defines KEYSTORE, KS_PASS y KEY_ALIAS la firma con apksigner;
#        si no, deja la salida alineada pero SIN firmar (fírmala con tu paso actual).
#
# Qué hace:
#  * Exportar: cuando el juego escribe partida_*.txt, se abre "Guardar como" del
#    sistema y copia ahí el archivo (eliges carpeta y nombre).
#  * Importar: cuando el juego abre la pantalla "Importar partida", se abre el
#    selector del sistema; el archivo elegido se copia a la carpeta del juego
#    como partida_*.txt y aparece en la lista.
# No toca game.droid ni el código GML.
set -euo pipefail

IN="${1:?uso: saf_patch.sh entrada.apk salida.apk}"
OUT="${2:?uso: saf_patch.sh entrada.apk salida.apk}"
IN="$(realpath "$IN")"
OUT="$(realpath -m "$OUT")"

W="$(mktemp -d)"
trap 'rm -rf "$W"' EXIT

SDK="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-/usr/local/lib/android/sdk}}"
BT="$(ls -d "$SDK"/build-tools/* | sort -V | tail -1)"
AJAR="$(ls -d "$SDK"/platforms/android-*/android.jar | sort -V | tail -1)"
echo ">> build-tools: $BT"
echo ">> android.jar: $AJAR"

APKTOOL_V=2.10.0
curl -fsSL -o "$W/apktool.jar" \
  "https://github.com/iBotPeaches/Apktool/releases/download/v${APKTOOL_V}/apktool_${APKTOOL_V}.jar"

# ---------------------------------------------------------------- fuentes Java
SRC="$W/src/com/undertaleyellowapp/game"
mkdir -p "$SRC"

cat > "$SRC/UtyBridgeProvider.java" <<'JAVA'
package com.undertaleyellowapp.game;

import android.app.Application;
import android.content.ContentProvider;
import android.content.ContentValues;
import android.content.Context;
import android.database.Cursor;
import android.net.Uri;
import android.util.Log;

/** Solo sirve para arrancar UtyBridge cuando se abre la app. */
public class UtyBridgeProvider extends ContentProvider {
    @Override
    public boolean onCreate() {
        try {
            Context c = getContext();
            if (c != null) {
                UtyBridge.start((Application) c.getApplicationContext());
            }
        } catch (Throwable t) {
            Log.e(UtyBridge.TAG, "no arranco", t);
        }
        return true;
    }

    @Override
    public Cursor query(Uri u, String[] p, String s, String[] a, String o) { return null; }

    @Override
    public String getType(Uri u) { return null; }

    @Override
    public Uri insert(Uri u, ContentValues v) { return null; }

    @Override
    public int delete(Uri u, String s, String[] a) { return 0; }

    @Override
    public int update(Uri u, ContentValues v, String s, String[] a) { return 0; }
}
JAVA

cat > "$SRC/UtyBridge.java" <<'JAVA'
package com.undertaleyellowapp.game;

import android.app.Activity;
import android.app.Application;
import android.content.Context;
import android.content.Intent;
import android.os.Bundle;
import android.os.FileObserver;
import android.os.Handler;
import android.os.Looper;
import android.util.Log;

import java.io.File;
import java.util.ArrayList;
import java.util.List;

/** Vigila la carpeta de guardado del juego y abre los selectores del sistema. */
final class UtyBridge {
    static final String TAG = "UtyBridge";
    static final int MODE_EXPORT = 1;
    static final int MODE_IMPORT = 2;

    private static final List<FileObserver> OBSERVERS = new ArrayList<FileObserver>();
    private static final Handler UI = new Handler(Looper.getMainLooper());

    private static Application app;
    private static Activity top;
    private static int resumed;
    private static boolean busy;
    private static long startedAt;
    private static long resumedAt;
    private static long lastDirOpen;
    private static long suppressUntil;
    private static String suppressName;

    private UtyBridge() {}

    static synchronized void start(Application a) {
        if (app != null) return;
        app = a;
        startedAt = System.currentTimeMillis();

        a.registerActivityLifecycleCallbacks(new Application.ActivityLifecycleCallbacks() {
            @Override public void onActivityCreated(Activity x, Bundle b) {}
            @Override public void onActivityStarted(Activity x) {}
            @Override public void onActivityResumed(Activity x) {
                synchronized (UtyBridge.class) {
                    resumed++;
                    resumedAt = System.currentTimeMillis();
                    if (!(x instanceof UtyBridgeActivity)) top = x;
                }
            }
            @Override public void onActivityPaused(Activity x) {
                synchronized (UtyBridge.class) {
                    resumed = Math.max(0, resumed - 1);
                }
            }
            @Override public void onActivityStopped(Activity x) {}
            @Override public void onActivitySaveInstanceState(Activity x, Bundle b) {}
            @Override public void onActivityDestroyed(Activity x) {
                synchronized (UtyBridge.class) {
                    if (x == top) top = null;
                }
            }
        });

        watch(a.getFilesDir());
        watch(a.getExternalFilesDir(null));
    }

    private static void watch(File dir) {
        if (dir == null) return;
        try {
            dir.mkdirs();
            final String path = dir.getAbsolutePath();
            FileObserver fo = new FileObserver(path, FileObserver.OPEN | FileObserver.CLOSE_WRITE) {
                @Override
                public void onEvent(int event, String name) {
                    try {
                        handle(path, event & FileObserver.ALL_EVENTS, name);
                    } catch (Throwable t) {
                        Log.e(TAG, "evento", t);
                    }
                }
            };
            fo.startWatching();
            OBSERVERS.add(fo); // referencia fuerte, si no el GC lo detiene
            Log.i(TAG, "vigilando " + path);
        } catch (Throwable t) {
            Log.e(TAG, "watch " + dir, t);
        }
    }

    private static boolean isSave(String name) {
        return name.startsWith("partida") && name.endsWith(".txt");
    }

    private static void handle(String dir, int ev, String name) {
        long now = System.currentTimeMillis();

        if (name != null) {
            // Exportar: el juego terminó de escribir partida_*.txt
            if ((ev & FileObserver.CLOSE_WRITE) != 0 && isSave(name)) {
                synchronized (UtyBridge.class) {
                    if (name.equals(suppressName) && now < suppressUntil) return;
                }
                Log.i(TAG, "exportar " + name);
                launch(MODE_EXPORT, dir, name);
            }
            return;
        }

        // Importar: el juego abrió la propia carpeta (file_find_first)
        if ((ev & FileObserver.OPEN) != 0) {
            long prev;
            boolean warm;
            synchronized (UtyBridge.class) {
                prev = lastDirOpen;
                lastDirOpen = now;
                warm = (now - startedAt > 12000) && (now - resumedAt > 3000);
            }
            boolean quiet = (now - prev) > 3000; // solo el primer evento tras un rato sin eventos
            if (quiet && warm) {
                Log.i(TAG, "importar");
                launch(MODE_IMPORT, dir, null);
            }
        }
    }

    private static void launch(final int mode, final String dir, final String name) {
        synchronized (UtyBridge.class) {
            if (busy || app == null || resumed <= 0) return;
            busy = true;
        }
        UI.post(new Runnable() {
            @Override
            public void run() {
                try {
                    Context c = top != null ? top : app;
                    Intent i = new Intent(c, UtyBridgeActivity.class);
                    i.putExtra("mode", mode);
                    i.putExtra("dir", dir);
                    if (name != null) i.putExtra("name", name);
                    if (c == app) i.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
                    c.startActivity(i);
                } catch (Throwable t) {
                    Log.e(TAG, "launch", t);
                    pickerClosed();
                }
            }
        });
    }

    static synchronized void pickerClosed() {
        busy = false;
        lastDirOpen = System.currentTimeMillis();
    }

    static synchronized void suppress(String name) {
        suppressName = name;
        suppressUntil = System.currentTimeMillis() + 4000;
    }
}
JAVA

cat > "$SRC/UtyBridgeActivity.java" <<'JAVA'
package com.undertaleyellowapp.game;

import android.app.Activity;
import android.content.Intent;
import android.database.Cursor;
import android.net.Uri;
import android.os.Bundle;
import android.provider.OpenableColumns;
import android.util.Log;
import android.widget.Toast;

import java.io.Closeable;
import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;

/** Actividad transparente: abre el selector del sistema y copia el archivo. */
public class UtyBridgeActivity extends Activity {
    private static final int REQ_EXPORT = 7101;
    private static final int REQ_IMPORT = 7102;

    private String dir;
    private String name;

    @Override
    protected void onCreate(Bundle b) {
        super.onCreate(b);
        if (b != null) { // recreada por el sistema, no hacemos nada
            finish();
            return;
        }
        Intent in = getIntent();
        int mode = in.getIntExtra("mode", 0);
        dir = in.getStringExtra("dir");
        name = in.getStringExtra("name");
        try {
            if (mode == UtyBridge.MODE_EXPORT) {
                Intent p = new Intent(Intent.ACTION_CREATE_DOCUMENT);
                p.addCategory(Intent.CATEGORY_OPENABLE);
                p.setType("text/plain");
                p.putExtra(Intent.EXTRA_TITLE, name);
                startActivityForResult(p, REQ_EXPORT);
            } else if (mode == UtyBridge.MODE_IMPORT) {
                Intent p = new Intent(Intent.ACTION_OPEN_DOCUMENT);
                p.addCategory(Intent.CATEGORY_OPENABLE);
                p.setType("*/*");
                startActivityForResult(p, REQ_IMPORT);
            } else {
                finish();
            }
        } catch (Throwable t) {
            Log.e(UtyBridge.TAG, "selector", t);
            toast("No se pudo abrir el selector de archivos");
            finish();
        }
    }

    @Override
    protected void onActivityResult(int req, int res, Intent data) {
        super.onActivityResult(req, res, data);
        try {
            if (res == RESULT_OK && data != null && data.getData() != null) {
                if (req == REQ_EXPORT) doExport(data.getData());
                else if (req == REQ_IMPORT) doImport(data.getData());
            }
        } catch (Throwable t) {
            Log.e(UtyBridge.TAG, "copiar", t);
            toast("Error: " + t.getMessage());
        }
        finish();
    }

    @Override
    protected void onDestroy() {
        super.onDestroy();
        UtyBridge.pickerClosed();
    }

    private void doExport(Uri u) throws IOException {
        File src = new File(dir, name);
        if (!src.isFile()) {
            toast("No encontré el archivo a exportar");
            return;
        }
        InputStream in = null;
        OutputStream out = null;
        try {
            in = new FileInputStream(src);
            try {
                out = getContentResolver().openOutputStream(u, "wt");
            } catch (Exception e) {
                out = getContentResolver().openOutputStream(u, "w");
            }
            if (out == null) throw new IOException("sin destino");
            copy(in, out);
        } finally {
            closeQuietly(in);
            closeQuietly(out);
        }
        toast("Partida exportada");
    }

    private void doImport(Uri u) throws IOException {
        String disp = null;
        Cursor c = null;
        try {
            c = getContentResolver().query(u, new String[] { OpenableColumns.DISPLAY_NAME }, null, null, null);
            if (c != null && c.moveToFirst()) disp = c.getString(0);
        } catch (Exception ignored) {
        } finally {
            if (c != null) c.close();
        }

        String base = (disp == null || disp.length() == 0) ? "importada" : disp;
        base = base.replaceAll("[^A-Za-z0-9._-]", "_");
        int dot = base.lastIndexOf('.');
        if (dot > 0) base = base.substring(0, dot);
        if (!base.startsWith("partida")) base = "partida_" + base;
        String destName = base + ".txt";

        InputStream in = null;
        OutputStream out = null;
        try {
            in = getContentResolver().openInputStream(u);
            if (in == null) throw new IOException("no pude leer el archivo");
            UtyBridge.suppress(destName);
            out = new FileOutputStream(new File(dir, destName));
            copy(in, out);
        } finally {
            closeQuietly(in);
            closeQuietly(out);
        }
        UtyBridge.suppress(destName);
        toast("Importado como " + destName);
    }

    private static void copy(InputStream in, OutputStream out) throws IOException {
        byte[] buf = new byte[32768];
        int n;
        while ((n = in.read(buf)) != -1) out.write(buf, 0, n);
        out.flush();
    }

    private static void closeQuietly(Closeable c) {
        if (c == null) return;
        try { c.close(); } catch (IOException ignored) {}
    }

    private void toast(String m) {
        Toast.makeText(getApplicationContext(), m, Toast.LENGTH_LONG).show();
    }
}
JAVA

# ------------------------------------------------------------ compilar a dex
mkdir -p "$W/cls" "$W/dex"
javac -source 8 -target 8 -Xlint:-options -cp "$AJAR" -d "$W/cls" "$SRC"/*.java
# shellcheck disable=SC2046
"$BT/d8" --release --min-api 21 --lib "$AJAR" --output "$W/dex" $(find "$W/cls" -name '*.class')
[ -f "$W/dex/classes.dex" ] || { echo "d8 no generó classes.dex"; exit 1; }

# ---------------------------------------------- decodificar y parchear manifest
java -jar "$W/apktool.jar" d -s -f -o "$W/app" "$IN"

python3 - "$W/app/AndroidManifest.xml" <<'PY'
import sys
p = sys.argv[1]
s = open(p, encoding="utf-8").read()
if "UtyBridgeActivity" in s:
    sys.exit(0)
add = (
    '    <activity android:name="com.undertaleyellowapp.game.UtyBridgeActivity"'
    ' android:exported="false" android:excludeFromRecents="true"'
    ' android:theme="@android:style/Theme.Translucent.NoTitleBar"/>\n'
    '    <provider android:name="com.undertaleyellowapp.game.UtyBridgeProvider"'
    ' android:authorities="com.undertaleyellowapp.game.utybridge"'
    ' android:exported="false" android:initOrder="100"/>\n'
)
if "</application>" not in s:
    sys.exit("No encontré </application> en el manifest")
s = s.replace("</application>", add + "</application>", 1)
open(p, "w", encoding="utf-8").write(s)
print(">> manifest parcheado")
PY

# ------------------------------------------------------ reconstruir y añadir dex
java -jar "$W/apktool.jar" b -o "$W/built.apk" "$W/app"

if unzip -l "$W/built.apk" | grep -q ' classes2.dex$'; then
  echo "El APK ya tiene classes2.dex; hay que renombrar el nuevo (classes3.dex)."
  cp "$W/dex/classes.dex" "$W/classes3.dex"
  (cd "$W" && zip -q built.apk classes3.dex)
else
  cp "$W/dex/classes.dex" "$W/classes2.dex"
  (cd "$W" && zip -q built.apk classes2.dex)
fi

"$BT/zipalign" -f -p 4 "$W/built.apk" "$OUT"

if [ -n "${KEYSTORE:-}" ]; then
  "$BT/apksigner" sign --ks "$KEYSTORE" --ks-pass "pass:${KS_PASS:?falta KS_PASS}" \
    --ks-key-alias "${KEY_ALIAS:?falta KEY_ALIAS}" "$OUT"
  echo ">> firmado"
else
  echo ">> SIN FIRMAR: fírmalo con tu paso habitual"
fi

if [ -x "$BT/aapt2" ]; then
  "$BT/aapt2" dump xmltree --file AndroidManifest.xml "$OUT" | grep -q UtyBridgeProvider \
    && echo ">> verificado: el manifest incluye UtyBridge" \
    || { echo "!! el manifest NO incluye UtyBridge"; exit 1; }
fi
echo ">> listo: $OUT"
