import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// Hourly chime: bar bell icon + popup panel (chime toggle + DND window).
// Structure copied from the official agents plugin: Panel owns lifecycle/IPC,
// BarIconButton is the bar button, KeyboardPanel is the anchored popup panel.
Panel {
  id: root
  moduleName: "com.github.kongzong.hourly-chime"
  ipcTarget: "com.github.kongzong.hourly-chime"

  // The bar sizes each slot from the root's implicit size — must bind to the button
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color dim: Qt.darker(foreground, 1.55)
  // Resolved once at root. qs.Commons exports the singletons `Color` / `Style`
  // / `Border` / `Util` — there is no type named `Commons`, so `Commons.Color`
  // would throw ReferenceError the moment the binding is evaluated.
  readonly property color accent: Color.accent

  // ------------------------------------------------------------- state
  // chimeOn instead of enabled: Item already has `enabled`, do not shadow it
  property bool chimeOn: false
  property int dndStartMin: 23 * 60
  property int dndEndMin: 7 * 60
  // Wall-clock hour of the last chime we handled. Guarantees at most one
  // notification per hour regardless of how many ticks land in minute 0.
  property string lastFiredHour: ""

  readonly property string statePath: (Quickshell.env("XDG_STATE_HOME") || (Quickshell.env("HOME") + "/.local/state")) + "/hourly-chime.json"

  // -------------------------------------------------------------- i18n
  // Catalogs live in <plugin>/i18n/<language>.json beside the QML, following
  // the language Omarchy picks under Setup > Language (~/.config/omarchy/
  // language, owned by omarchy-language). qs.Commons.Translations merges
  // current language -> base language -> en.json -> the key itself, and
  // watches the files, so switching language re-renders without a restart.
  // Plugins load through the qs:// scheme, so Qt.resolvedUrl can hand back a
  // qs:// URL rather than file:// — strip whatever scheme it returns and keep
  // the absolute path. If the result is not rooted, the catalog simply misses
  // and every call falls back to its English text.
  readonly property string i18nDir: {
    var u = String(Qt.resolvedUrl("i18n")).replace(/^[A-Za-z][A-Za-z0-9+.-]*:/, "")
    u = u.replace(/^\/\//, "")   // drop the // authority separator of scheme:///
    return u.charAt(0) === "/" ? u.replace(/\/+$/, "") : ""
  }

  Translations {
    id: strings
    directory: root.i18nDir
  }

  // Every call site passes its English text as the fallback: if a catalog is
  // missing or unreadable the UI still reads in English, never as raw keys.
  function tr(key, fallback) {
    return strings.t(key, fallback)
  }

  function fmtTime(min) {
    var h = Math.floor(min / 60) % 24
    var m = min % 60
    return (h < 10 ? "0" : "") + h + ":" + (m < 10 ? "0" : "") + m
  }

  function parseTime(str, fallbackMin) {
    var m = String(str || "").match(/^(\d{1,2}):(\d{2})$/)
    if (!m) return fallbackMin
    var v = Number(m[1]) * 60 + Number(m[2])
    return (v >= 0 && v < 1440) ? v : fallbackMin
  }

  // DND check, supports ranges across midnight (e.g. 23:00–07:00).
  function inDnd(minOfDay) {
    if (dndStartMin === dndEndMin) return false
    if (dndStartMin < dndEndMin) return minOfDay >= dndStartMin && minOfDay < dndEndMin
    return minOfDay >= dndStartMin || minOfDay < dndEndMin
  }

  function loadState(text) {
    var data = {}
    try { data = JSON.parse(text) } catch (e) { data = {} }
    chimeOn = data.enabled === true
    dndStartMin = parseTime(data.dndStart, 23 * 60)
    dndEndMin = parseTime(data.dndEnd, 7 * 60)
  }

  function saveState() {
    // Older versions also stored a reminder list under "alarms"; it is simply
    // dropped here, so the file is rewritten clean on the first save.
    stateFile.setText(JSON.stringify({
      enabled: root.chimeOn,
      dndStart: fmtTime(root.dndStartMin),
      dndEnd: fmtTime(root.dndEndMin)
    }, null, 2) + "\n")
  }

  function shiftDndStart(delta) {
    root.dndStartMin = ((root.dndStartMin + delta) % 1440 + 1440) % 1440
    root.saveState()
  }

  function shiftDndEnd(delta) {
    root.dndEndMin = ((root.dndEndMin + delta) % 1440 + 1440) % 1440
    root.saveState()
  }

  FileView {
    id: stateFile
    path: root.statePath
    watchChanges: true
    atomicWrites: true
    printErrors: false
    onLoaded: root.loadState(text())
    onLoadFailed: root.loadState("{}")
    onFileChanged: reload()
  }

  // ------------------------------------------------------------- fire
  readonly property string chimePath: Qt.resolvedUrl("chime.wav").toString().replace(/^file:\/\//, "")

  function fireChime(minOfDay) {
    if (!root.chimeOn) return
    if (root.inDnd(minOfDay)) return
    Quickshell.execDetached(["paplay", root.chimePath])
    Quickshell.execDetached([
      "notify-send", "-a", "hourly-chime",
      root.tr("hourlyChime.notificationTitle", "Hourly Chime"),
      root.tr("hourlyChime.notificationBody", "It's %1").arg(fmtTime(minOfDay))
    ])
  }

  // ------------------------------------------------------- minute tick
  // Aim a little AFTER the next minute boundary, not exactly at it. QQmlTimer
  // schedules the next tick relative to the *previous tick timestamp*, but the
  // Date below is read a few ms later inside the handler; targeting :00.000
  // made the next tick land at :59.99x — still minute 0 — so the hour chimed
  // twice (:00.003 and :00.998). The 50 ms epsilon keeps ticks on the far
  // side of the boundary; hourKey() below is the hard guarantee if a slow
  // handler, a suspend or a clock step defeats it anyway.
  // See tools/repro-double-chime.mjs for the regression replay.
  function msToNextMinute() {
    var now = new Date()
    var next = new Date(now.getFullYear(), now.getMonth(), now.getDate(),
                        now.getHours(), now.getMinutes() + 1, 0, 50)
    // The clamp only guards a backwards clock step / DST normalisation.
    return Math.max(50, next.getTime() - now.getTime())
  }

  // Second line of defence: one chime per wall-clock hour, whatever the tick
  // timing. Deliberately conservative — if the clock steps or DST repeats an
  // hour, we would rather skip than chime twice. The hour is marked handled
  // even when the chime is off or inside the quiet window: no late catch-up.
  function hourKey(d) {
    return d.getFullYear() + "-" + d.getMonth() + "-" + d.getDate() + "-" + d.getHours()
  }

  // Wake every minute and fire at :00. If a tick was missed (e.g. after
  // sleep), realign silently — no catch-up.
  Timer {
    id: tickTimer
    repeat: true
    running: true
    triggeredOnStart: false
    interval: 60000
    onTriggered: {
      var now = new Date()
      if (now.getMinutes() === 0) {
        var key = root.hourKey(now)
        if (key !== root.lastFiredHour) {
          root.lastFiredHour = key
          root.fireChime(now.getHours() * 60 + now.getMinutes())
        }
      }
      tickTimer.interval = root.msToNextMinute()
    }
  }

  Component.onCompleted: {
    tickTimer.interval = root.msToNextMinute()
    // The catalogs are read silently (printErrors: false), so an unresolved
    // directory would just look like "no translation exists" — say so once.
    if (root.i18nDir === "")
      console.warn("hourly-chime: i18n directory unresolved, falling back to English")
  }

  // Small −/+ stepper button used in the DND row
  component StepButton: Text {
    property string glyph: "-"
    signal stepped()
    text: glyph
    color: mouse.containsMouse ? root.accent : root.foreground
    font.family: root.bar ? root.bar.fontFamily : Style.font.family
    font.pixelSize: Style.font.body
    font.weight: Font.DemiBold

    MouseArea {
      id: mouse
      anchors.fill: parent
      anchors.margins: -Style.space(6)
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: parent.stepped()
    }
  }

  // --------------------------------------------------------- bar button
  // Wristwatch glyph (md-watch, U+F0589) reads as "a watch", not as an alarm.
  // MDI has no "off" variant for it, so the off state is the same glyph dimmed
  // instead of a slashed bell — the shape stays stable, only the weight changes.
  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "\uDB81\uDD89"
    opacity: root.chimeOn ? 1.0 : 0.42
    tooltipText: root.chimeOn
                 ? root.tr("hourlyChime.tooltipOn", "Hourly chime on · quiet %1–%2")
                     .arg(root.fmtTime(root.dndStartMin)).arg(root.fmtTime(root.dndEndMin))
                 : root.tr("hourlyChime.tooltipOff", "Hourly chime off")
    onPressed: function(buttonCode) {
      if (buttonCode === Qt.LeftButton) root.toggle()
    }
  }

  // -------------------------------------------------------- popup panel
  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    contentWidth: panel.fittedContentWidth(Style.space(300))
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(520))

    Column {
      id: column
      width: parent.width
      spacing: Style.space(14)

      // ---- Chime toggle ----
      Item {
        width: parent.width
        height: Math.max(titleText.implicitHeight, switchControl.trackHeight)

        Text {
          id: titleText
          anchors.left: parent.left
          anchors.verticalCenter: parent.verticalCenter
          text: root.tr("hourlyChime.title", "Hourly Chime")
          color: root.foreground
          font.family: bar ? bar.fontFamily : Style.font.family
          font.pixelSize: Style.font.body
          font.weight: Font.DemiBold
        }

        ToggleSwitch {
          id: switchControl
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          checked: root.chimeOn
          foreground: root.foreground
          onToggled: {
            root.chimeOn = !root.chimeOn  // ToggleSwitch does not flip itself; caller owns the value
            root.saveState()
          }
        }
      }

      // ---- DND window, visually part of the chime section ----
      Item {
        width: parent.width
        height: Style.space(28)

        // Left: label + start group [- 23:00 +]
        Text {
          id: dndLabel
          anchors.left: parent.left
          anchors.verticalCenter: parent.verticalCenter
          text: root.tr("hourlyChime.doNotDisturb", "Do not disturb")
          color: root.dim
          font.family: bar ? bar.fontFamily : Style.font.family
          font.pixelSize: Style.font.bodySmall
        }
        StepButton {
          id: dndMinusStart
          anchors.left: dndLabel.right
          anchors.leftMargin: Style.space(10)
          anchors.verticalCenter: parent.verticalCenter
          glyph: "-"
          onStepped: root.shiftDndStart(-15)
        }
        Text {
          id: dndTimeStart
          anchors.left: dndMinusStart.right
          anchors.leftMargin: Style.space(8)
          anchors.verticalCenter: parent.verticalCenter
          text: root.fmtTime(root.dndStartMin)
          color: root.foreground
          font.family: bar ? bar.fontFamily : Style.font.family
          font.pixelSize: Style.font.body
        }
        StepButton {
          id: dndPlusStart
          anchors.left: dndTimeStart.right
          anchors.leftMargin: Style.space(8)
          anchors.verticalCenter: parent.verticalCenter
          glyph: "+"
          onStepped: root.shiftDndStart(15)
        }

        // Range connector between the two groups, centered in the gap
        Text {
          anchors.left: dndPlusStart.right
          anchors.right: dndMinusEnd.left
          anchors.verticalCenter: parent.verticalCenter
          horizontalAlignment: Text.AlignHCenter
          text: root.tr("hourlyChime.rangeTo", "to")
          color: root.dim
          font.family: bar ? bar.fontFamily : Style.font.family
          font.pixelSize: Style.font.body
        }

        // Right: end group [- 07:00 +], flush right
        StepButton {
          id: dndMinusEnd
          anchors.right: dndTimeEnd.left
          anchors.rightMargin: Style.space(8)
          anchors.verticalCenter: parent.verticalCenter
          glyph: "-"
          onStepped: root.shiftDndEnd(-15)
        }
        Text {
          id: dndTimeEnd
          anchors.right: dndPlusEnd.left
          anchors.rightMargin: Style.space(8)
          anchors.verticalCenter: parent.verticalCenter
          text: root.fmtTime(root.dndEndMin)
          color: root.foreground
          font.family: bar ? bar.fontFamily : Style.font.family
          font.pixelSize: Style.font.body
        }
        StepButton {
          id: dndPlusEnd
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          glyph: "+"
          onStepped: root.shiftDndEnd(15)
        }
      }
    }
  }
}
