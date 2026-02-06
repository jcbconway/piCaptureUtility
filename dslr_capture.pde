// Processing 4 (Java mode)
// Pi Camera Controller UI (tabs per camera)
// - Global settings: controller base URL, frame size
// - On startup: GET /cameras, build tabs
// - Per-camera tab:
//     [Shoot] button
//     [Continuous] toggle (loops shots)
//     ISO field + [Apply]
//     Exposure(s) field (0 = use /shoot; >0 = use /bulb seconds)
//     [Set Folder] to choose local download dir (per camera)
//     [Delete after download] toggle
// - Auto pulls /files (latest) and downloads newest image for that camera,
//   then optionally DELETEs it on the controller.
//
// Notes:
// - We tag captures with a filename stem = <cameraSafeName>-%Y%m%d... to
//   disambiguate multi-cam downloads, so we can filter /files results.
// - You can resize the window; layout is responsive-ish.

import java.net.http.*;
import java.net.URI;
import java.net.URLEncoder;
import java.nio.charset.StandardCharsets;
import java.time.Duration;
import java.nio.file.*;
import java.io.*;
import processing.data.*;
import javax.swing.*;
import java.awt.*;

// ---------- Global settings ----------
String controllerBase = "http://pi:8080"; // set your Pi address/port here
int initialW = 600, initialH = 700;

// UI state
ArrayList<CamTab> tabs = new ArrayList<CamTab>();
int activeTab = 0;

// HTTP client
HttpClient http = HttpClient.newBuilder()
  .connectTimeout(Duration.ofSeconds(5))
  .build();

// colors
int bg = color(18, 21, 25);
int fg = color(230);
int panel = color(32, 36, 44);
int accent = color(80, 160, 255);
int bad = color(255, 90, 90);
PFont uiFont;

void settings() {
  size(initialW, initialH);
}

void setup() {
  surface.setTitle("Pi Camera Controller");
  uiFont = createFont("Roboto Mono", 14, true);
  textFont(uiFont);

  // Try to fetch cameras
  String camsTxt = getText("/cameras");
  ArrayList<String[]> cams = parseCamerasText(camsTxt); // [name, port]
  if (cams.isEmpty()) {
    println("No cameras detected. UI will show empty state.");
  }
  for (String[] c : cams) {
    tabs.add(new CamTab(c[0], c[1]));
  }
  if (tabs.size() == 0) {
    // Add a placeholder to show where things would be
    tabs.add(new CamTab("No Camera", "usb:000,000", true));
  }
}

void draw() {
  background(bg);
  drawTopBar();
  drawTabs();
  if (activeTab >= 0 && activeTab < tabs.size()) {
    tabs.get(activeTab).update();
    tabs.get(activeTab).draw();
  }
}

// ---------- HTTP helpers ----------
void runAsync(String name, Runnable r) {
  Thread t = new Thread(r);
  t.setName(name);
  t.setDaemon(true);
  t.start();
}

String getText(String pathAndQuery) {
  try {
    HttpRequest req = HttpRequest.newBuilder()
      .uri(URI.create(controllerBase + pathAndQuery))
      .timeout(Duration.ofSeconds(15))
      .GET()
      .build();
    HttpResponse<String> resp = http.send(req, HttpResponse.BodyHandlers.ofString());
    return resp.body();
  } catch (Exception e) {
    println("GET error " + pathAndQuery + " : " + e);
    return "";
  }
}

JSONObject getJSON(String pathAndQuery) {
  String s = getText(pathAndQuery);
  if (s == null || s.isEmpty()) return null;
  try {
    return JSONObject.parse(s);
  } catch (Exception e) {
    println("JSON parse error: " + e + "\n" + s);
    return null;
  }
}

JSONArray getJSONA(String pathAndQuery) {
  String s = getText(pathAndQuery);
  if (s == null || s.isEmpty()) return null;
  try {
    return JSONArray.parse(s);
  } catch (Exception e) {
    println("JSON array parse error: " + e + "\n" + s);
    return null;
  }
}

JSONObject postJSON(String pathAndQuery) {
  try {
    HttpRequest req = HttpRequest.newBuilder()
      .uri(URI.create(controllerBase + pathAndQuery))
      .timeout(Duration.ofSeconds(120))
      .POST(HttpRequest.BodyPublishers.noBody())
      .build();
    HttpResponse<String> resp = http.send(req, HttpResponse.BodyHandlers.ofString());
    String s = resp.body();
    if (s == null || s.isEmpty()) return null;
    return JSONObject.parse(s);
  } catch (Exception e) {
    println("POST error " + pathAndQuery + " : " + e);
    return null;
  }
}

boolean deleteRemote(String pathAndQuery) {
  try {
    HttpRequest req = HttpRequest.newBuilder()
      .uri(URI.create(controllerBase + pathAndQuery))
      .timeout(Duration.ofSeconds(30))
      .method("DELETE", HttpRequest.BodyPublishers.noBody())
      .build();
    HttpResponse<String> resp = http.send(req, HttpResponse.BodyHandlers.ofString());
    int code = resp.statusCode();
    return (code >= 200 && code < 300);
  } catch (Exception e) {
    println("DELETE error " + pathAndQuery + " : " + e);
    return false;
  }
}

boolean downloadFile(String remoteName, Path localFile) {
  try {
    HttpRequest req = HttpRequest.newBuilder()
      .uri(URI.create(controllerBase + "/files/" + url(remoteName)))
      .timeout(Duration.ofSeconds(300))
      .GET()
      .build();
    HttpResponse<InputStream> resp = http.send(req, HttpResponse.BodyHandlers.ofInputStream());
    if (resp.statusCode() >= 200 && resp.statusCode() < 300) {
      Files.createDirectories(localFile.getParent());
      try (InputStream in = resp.body(); OutputStream out = Files.newOutputStream(localFile)) {
        in.transferTo(out);
      }
      return true;
    }
    println("Download failed HTTP " + resp.statusCode());
  } catch (Exception e) {
    println("Download error: " + e);
  }
  return false;
}

String url(String s) {
  try {
    return URLEncoder.encode(s, StandardCharsets.UTF_8.toString());
  } catch (Exception e) { return s; }
}

// ---------- Parse /cameras plain text ----------
ArrayList<String[]> parseCamerasText(String txt) {
  ArrayList<String[]> out = new ArrayList<String[]>();
  if (txt == null) return out;
  String[] lines = txt.split("\\r?\\n");
  for (String line : lines) {
    line = line.trim();
    if (line.isEmpty()) continue;
    if (!line.contains("usb:")) continue;
    // Expect: "<model name>    usb:BUS,DEV"
    int idx = line.lastIndexOf("usb:");
    if (idx > 0) {
      String name = line.substring(0, idx).trim();
      String port = line.substring(idx).trim();
      out.add(new String[]{name, port});
    }
  }
  return out;
}

// ---------- UI drawing ----------
void drawTopBar() {
  fill(panel);
  noStroke();
  rect(0, 0, width, 48);
  fill(fg);
  textAlign(LEFT, CENTER);
  text("Controller: " + controllerBase, 16, 24);

  // Controller base editing (click to toggle)
  fill(accent);
  textAlign(RIGHT, CENTER);
  text("[E] Edit  [R] Refresh Cameras", width - 16, 24);
}

void drawTabs() {
  // Tab bar under top
  int y = 48;
  int tabH = 36;
  int x = 0;
  int tabW = max(140, width / max(1, tabs.size()));
  for (int i = 0; i < tabs.size(); i++) {
    if (i == activeTab) fill(panel); else fill(24);
    rect(x, y, tabW, tabH);
    fill(fg);
    textAlign(CENTER, CENTER);
    text(tabs.get(i).title, x + tabW/2, y + tabH/2);
    x += tabW;
  }
}

// ---------- Mouse/keyboard ----------
void mousePressed() {
  // switch tabs
  int y = 48, tabH = 36;
  if (mouseY > y && mouseY < y + tabH) {
    int tabW = max(140, width / max(1, tabs.size()));
    int idx = constrain(mouseX / tabW, 0, tabs.size()-1);
    activeTab = idx;
    return;
  }
  if (activeTab >= 0 && activeTab < tabs.size()) {
    tabs.get(activeTab).mousePressed();
  }
}

void keyPressed() {
  if (key == 'e' || key == 'E') {
    String input = prompt("Controller Base URL", controllerBase);
    if (input != null && input.trim().length() > 0) {
      controllerBase = input.trim();
    }
  }
  if (key == 'r' || key == 'R') {
    String camsTxt = getText("/cameras");
    ArrayList<String[]> cams = parseCamerasText(camsTxt);
    tabs.clear();
    for (String[] c : cams) tabs.add(new CamTab(c[0], c[1]));
    if (tabs.isEmpty()) tabs.add(new CamTab("No Camera", "usb:000,000", true));
    activeTab = 0;
  }
  if (activeTab >= 0 && activeTab < tabs.size()) {
    tabs.get(activeTab).keyPressed();
  }
}

// crude prompt (Processing)
String prompt(String title, String defaultVal) {
  return javax.swing.JOptionPane.showInputDialog(
    /* parent */ null,
    title,
    defaultVal
  );
}

class CamTab {
  String name;
  String port;
  String title;
  String safeStem;

  boolean placeholder = false;
  String message = "";
  volatile boolean continuous = false;
  volatile boolean deleteAfter = false;
  volatile String folder = "";
  volatile String lastDownloaded = "";

  int iso = 1600;
  int exposureSec = 0;

  long nextActionAt = 0;

  // input focus
  boolean focusIso = false;
  boolean focusExp = false;

  // async state
  volatile boolean busyCapture = false;
  volatile boolean busyPoll = false;
  long lastPollAt = 0;       // throttle /files
  int pollEveryMs = 2000;    // poll every 2s

  CamTab(String name, String port) { this(name, port, false); }
  CamTab(String name, String port, boolean placeholder) {
    this.name = name;
    this.port = port;
    this.placeholder = placeholder;
    this.title = (placeholder ? "(none)" : name);
    this.safeStem = name.replaceAll("[^A-Za-z0-9]+", "_");
  }

  void update() {
    long now = millis();

    // Continuous scheduler: only schedules, actual work is async
    if (continuous && !placeholder && !busyCapture && now >= nextActionAt) {
      triggerShot(false);
      int cushion = max(5, min(20, exposureSec / 10));
      int waitS = (exposureSec > 0 ? exposureSec + cushion : 6);
      nextActionAt = now + waitS * 1000L;
    }

    // Throttled file polling (async)
    if (!placeholder && (now - lastPollAt) >= pollEveryMs && !busyPoll) {
      lastPollAt = now;
      pollAndDownloadLatestAsync();
    }
  }

  void draw() {
    int top = 48 + 36;
    int pad = 16;
    fill(panel);
    rect(0, top, width, height - top);

    int x = pad, y = top + pad;

    fill(fg);
    textAlign(LEFT, TOP);
    textSize(18);
    text(name + "  [" + port + "]", x, y);
    textSize(14);

    y += 36;

    drawButton(x, y, 140, 36, busyCapture ? "Working…" : "Shoot", () -> {
      if (!busyCapture) triggerShot(true);
    });

    drawToggle(x + 160, y, 180, 36, "Continuous", continuous, () -> {
      continuous = !continuous;
      if (continuous) nextActionAt = 0;
    });

    drawToggle(x + 360, y, 240, 36, "Delete after download", deleteAfter, () -> {
      deleteAfter = !deleteAfter;
    });

    y += 56;

    drawLabel(x, y, "ISO");
    drawField(x + 60, y - 4, 100, 28, str(iso), () -> { focusIso = true; focusExp = false; });
    drawButton(x + 170, y - 6, 90, 32, "Apply", () -> applyISO());

    drawLabel(x + 280, y, "Exposure (s)  0 = normal /shoot");
    drawField(x + 520, y - 4, 120, 28, str(exposureSec), () -> { focusExp = true; focusIso = false; });

    y += 56;

    drawLabel(x, y, "Download folder");
    String shown = (folder == null || folder.isEmpty()) ? "(not set)" : folder;
    drawButton(x + 160, y - 6, 140, 32, "Set Folder", () -> chooseFolder());
    fill(200);
    textAlign(LEFT, TOP);
    text(shown, x + 320, y);

    y += 56;

    fill(180);
    text("Last downloaded: " + (lastDownloaded == null ? "" : lastDownloaded), x, y);
    y += 24;
    if (message != null && !message.isEmpty()) {
      fill(220);
      text(message, x, y);
    }
  }

  // -------- actions (all async) --------
  void triggerShot(boolean userInitiated) {
    if (placeholder) return;
    if (userInitiated && (folder == null || folder.isEmpty())) {
      message = "Set a download folder first.";
      return;
    }
    if (busyCapture) return;

    final String stem = safeStem + "-%25Y%25m%25d-%25H%25M%25S";
    busyCapture = true;
    message = (exposureSec > 0) ? ("Bulb " + exposureSec + "s…") : "Shoot…";

    runAsync("capture-" + safeStem, () -> {
      JSONObject resp = null;
      try {
        if (exposureSec > 0) {
          String q = "/bulb?port=" + url(port) + "&seconds=" + exposureSec + "&filename=" + stem;
          resp = postJSON(q);
        } else {
          String q = "/shoot?port=" + url(port) + "&filename=" + stem;
          resp = postJSON(q);
        }
        if (resp != null && resp.hasKey("ok") && resp.getBoolean("ok")) {
          message = "Captured " + resp.getString("file");
        } else {
          message = "Capture failed (check exposure/ISO/cables).";
        }
      } catch (Exception e) {
        message = "Capture error: " + e.getMessage();
      } finally {
        busyCapture = false;
        // Kick a poll soon to catch the new file
        lastPollAt = 0;
      }
    });
  }

  void applyISO() {
    if (placeholder) return;
    final String q = "/set?port=" + url(port) + "&key=iso&value=" + iso;
    message = "Setting ISO…";
    runAsync("set-iso-" + safeStem, () -> {
      JSONObject resp = postJSON(q);
      message = (resp != null) ? "ISO set request sent." : "Failed to set ISO.";
    });
  }

  
  
  public void folderChosen(File sel) {
    if (sel != null) {
      folder = sel.getAbsolutePath();
      message = "Folder set: " + folder;
      println("[" + name + "] Download folder chosen: " + folder);
    } else {
      message = "Folder selection canceled.";
    }
  }

  // inside CamTab
  void chooseFolder() {
  runAsync("choose-folder-" + safeStem, () -> {
    Component parent = null;
    try { parent = (Component) surface.getNative(); } catch (Exception ignore) {}
    JFileChooser fc = new JFileChooser();
    fc.setFileSelectionMode(JFileChooser.DIRECTORIES_ONLY);
    fc.setDialogTitle("Choose download directory for " + name);
    int res = fc.showOpenDialog(parent);
    if (res == JFileChooser.APPROVE_OPTION) {
      java.io.File sel = fc.getSelectedFile();
      folder = sel.getAbsolutePath();
      message = "Folder set: " + folder;
    } else {
      message = "Folder selection canceled.";
    }
  });
}

  void pollAndDownloadLatestAsync() {
    if (placeholder || busyPoll) return;
    busyPoll = true;

    runAsync("poll-" + safeStem, () -> {
      try {
        JSONArray arr = getJSONA("/files?limit=12");
        if (arr == null) return;

        String latestForMe = null;
        for (int i = 0; i < arr.size(); i++) {
          JSONObject o = arr.getJSONObject(i);
          String n = o.getString("name");
          if (n != null && n.startsWith(safeStem)) { latestForMe = n; break; }
        }
        if (latestForMe == null) return;

        if (!latestForMe.equals(lastDownloaded)) {
          if (folder == null || folder.isEmpty()) return; // wait until set
          Path dest = Paths.get(folder, latestForMe);
          boolean ok = downloadFile(latestForMe, dest);
          if (ok) {
            lastDownloaded = latestForMe;
            message = "Downloaded " + latestForMe + " → " + dest.toString();
            if (deleteAfter) {
              boolean del = deleteRemote("/files/" + url(latestForMe));
              if (!del) message = "Downloaded but delete failed (check API perms).";
            }
          } else {
            message = "Download failed: " + latestForMe;
          }
        }
      } catch (Exception e) {
        message = "Poll error: " + e.getMessage();
      } finally {
        busyPoll = false;
      }
    });
  }

  // --- UI events & helpers (unchanged, except they don’t block now) ---
  ArrayList<int[]> hitboxes = new ArrayList<int[]>();
  ArrayList<Runnable> actions = new ArrayList<Runnable>();

  void drawButton(int x, int y, int w, int h, String label, Runnable onClick) {
    boolean hot = over(x,y,w,h);
    fill(hot ? accent : 64);
    stroke(0, 50);
    rect(x, y, w, h, 6);
    fill(255);
    textAlign(CENTER, CENTER);
    text(label, x + w/2, y + h/2);
    clickable(x,y,w,h,onClick);
  }

  void drawToggle(int x, int y, int w, int h, String label, boolean val, Runnable onClick) {
    boolean hot = over(x,y,w,h);
    fill(hot ? 70 : 54);
    stroke(0, 50);
    rect(x, y, w, h, 6);
    fill(val ? accent : 140);
    textAlign(LEFT, CENTER);
    text((val ? "⦿ " : "◯ ") + label, x + 10, y + h/2);
    clickable(x,y,w,h,onClick);
  }

  void drawLabel(int x, int y, String label) {
    fill(180); textAlign(LEFT, TOP); text(label, x, y);
  }

  void drawField(int x, int y, int w, int h, String val, Runnable onFocus) {
    boolean hot = over(x,y,w,h);
    fill(30); stroke(hot ? accent : 80); rect(x, y, w, h, 6);
    fill(230); textAlign(LEFT, CENTER); text(val, x + 8, y + h/2);
    clickable(x,y,w,h,onFocus);
  }

  void clickable(int x, int y, int w, int h, Runnable action) {
    hitboxes.add(new int[]{x,y,w,h,hitboxes.size()});
    actions.add(action);
  }

  void mousePressed() {
    for (int i = 0; i < hitboxes.size(); i++) {
      int[] b = hitboxes.get(i);
      if (over(b[0], b[1], b[2], b[3])) {
        if (!overField(focusIso, b, 0)) focusIso = false;
        if (!overField(focusExp, b, 0)) focusExp = false;
        actions.get(i).run();
        break;
      }
    }
    hitboxes.clear();
    actions.clear();
  }

  void keyPressed() {
    if (focusIso) {
      if (key == ENTER || key == RETURN) { focusIso = false; applyISO(); return; }
      if (key == BACKSPACE) { iso /= 10; return; }
      if (Character.isDigit(key)) {
        try { iso = constrain(Integer.parseInt(str(iso) + key), 50, 51200); } catch (Exception e) {}
      }
    } else if (focusExp) {
      if (key == ENTER || key == RETURN) { focusExp = false; return; }
      if (key == BACKSPACE) { exposureSec /= 10; return; }
      if (Character.isDigit(key)) {
        try { exposureSec = max(0, Integer.parseInt(str(exposureSec) + key)); } catch (Exception e) {}
      }
    }
  }

  boolean over(int x, int y, int w, int h) {
    return mouseX >= x && mouseX <= x + w && mouseY >= y && mouseY <= y + h;
  }
  boolean overField(boolean focus, int[] b, int dummy) { return focus && over(b[0], b[1], b[2], b[3]); }
  
}
