import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Paste a link, get an album: the panel hands a URL to the bundled `chapterdl`
// script, which splits the video on its chapters and tags each piece as a track.
//
// Button and popup live in this one file, with `anchorItem: button` as a direct
// binding, because that is what makes the popup open under its own button --
// assigning anchorItem imperatively across a Loader leaves it stranded mid-screen.
//
// All the real work is in `chapterdl`. This file only reads its line protocol
// (see the script's header) and paints the result, which keeps the download
// logic testable from a terminal and out of the shell's event loop.
Panel {
  id: root
  moduleName: "kuroshi.chapterdl"
  ipcTarget: "kuroshi.chapterdl"
  manageIpc: false

  // ---- Configuration, read from this widget's shell.json entry.
  readonly property string downloadDir: setting("downloadDir", "~/Music")
  readonly property string audioFormat: setting("audioFormat", "mp3")
  readonly property string audioQuality: setting("audioQuality", "320K")
  readonly property string playlistMode: setting("playlist", "auto")
  readonly property bool smartNaming: setting("smartNaming", true) === true
  readonly property bool embedArt: setting("embedArt", true) === true
  readonly property bool notifyOnFinish: setting("notify", true) === true
  readonly property bool autoPaste: setting("autoPaste", true) === true

  // ---- Job state.
  property string jobState: "idle"     // idle | running | done | error
  property string url: ""
  property string stage: ""
  property real pct: 0
  property var info: null
  property var tracks: []
  property var results: []
  property string errorText: ""

  // Set by the `grab` IPC call: the clipboard read is a process, so the start
  // has to wait for it to come back rather than firing on the next tick.
  property bool startWhenPasted: false

  // A cancelled run still fires onExited; without this it would be reported as
  // a failure, notification and all.
  property bool cancelling: false

  readonly property bool running: jobState === "running"
  readonly property bool canStart: !running && Model.looksLikeUrl(root.url)
  readonly property real overallPct: info
    ? Model.overallProgress(info.index, info.count, root.pct)
    : root.pct

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property string fontFamily: bar ? bar.fontFamily : ""

  // The script sits next to this file, wherever the plugin was installed.
  readonly property string pluginDir: {
    var u = String(Qt.resolvedUrl("."))
    if (u.indexOf("file://") === 0) u = u.substring(7)
    if (u.length > 1 && u.charAt(u.length - 1) === "/") u = u.substring(0, u.length - 1)
    return decodeURIComponent(u)
  }

  visible: true
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  // ---- Lifecycle.
  function open() {
    root.controller.show()
    // Only reach for the clipboard when there is nothing worth keeping on
    // screen -- re-opening mid-download must not overwrite a running job's URL.
    if (root.autoPaste && !root.running) clipboard.running = true
  }

  function close() { root.controller.hide() }
  function toggle() { root.opened ? root.close() : root.open() }

  function start() {
    if (!root.canStart) return

    root.jobState = "running"
    root.stage = "probing"
    root.pct = 0
    root.info = null
    root.tracks = []
    root.results = []
    root.errorText = ""

    var args = [
      root.pluginDir + "/chapterdl",
      "--dir", root.downloadDir,
      "--format", root.audioFormat,
      "--quality", root.audioQuality,
      "--playlist", root.playlistMode
    ]
    if (!root.smartNaming) args.push("--no-smart-naming")
    if (!root.embedArt) args.push("--no-art")
    args.push("--url", root.url)

    job.command = args
    job.running = true
  }

  // Cancelling has to reach yt-dlp and ffmpeg, not just the script that spawned
  // them. `running = false` does not even reliably reach the script, and the
  // script's own trap cannot finish the job while it sits blocked reading from a
  // converting yt-dlp -- so the walk happens in a separate process. The timer is
  // the backstop for anything that ignores SIGTERM.
  function killTree(signalName) {
    if (!job.processId) return false
    killer.command = [root.pluginDir + "/kill-tree", String(job.processId), signalName]
    killer.running = true
    return true
  }

  function cancel() {
    if (!root.running) return
    root.cancelling = true
    if (!root.killTree("TERM")) job.signal(15)
    killTimer.restart()

    root.jobState = "idle"
    root.stage = ""
    root.pct = 0
    root.info = null
  }

  Timer {
    id: killTimer
    interval: 4000
    onTriggered: {
      if (!job.running) return
      if (!root.killTree("KILL")) job.signal(9)
      job.running = false
    }
  }

  Process { id: killer }

  function openFolder() {
    var dir = root.results.length ? root.results[root.results.length - 1].dir : ""
    if (!dir) return
    opener.command = ["xdg-open", dir]
    opener.running = true
  }

  function notify(urgency, glyph, headline, body) {
    if (!root.notifyOnFinish) return
    notifier.command = ["omarchy-notification-send", "-u", urgency, "-g", glyph, headline, body]
    notifier.running = true
  }

  // ---- Backend events. One switch, mirroring the script's protocol.
  function handleEvent(line) {
    var event = Model.parseEvent(line)
    if (!event) return

    switch (event.kind) {
      case "stage":
        root.stage = event.value
        break
      case "progress":
        root.pct = event.value
        break
      case "info":
        root.info = event.value
        // A new video in a playlist run starts its own track list.
        root.tracks = []
        root.pct = 0
        break
      case "track":
        root.tracks = root.tracks.concat([event.value])
        break
      case "done":
        root.results = root.results.concat([event.value])
        break
      case "error":
        root.errorText = event.value
        break
    }
  }

  function finish(exitCode) {
    killTimer.stop()
    if (root.cancelling) {
      root.cancelling = false
      return
    }

    // The script reports per-video errors and keeps going, so a non-zero exit
    // with tracks on disk is a partial success -- say so rather than claiming
    // the whole run failed.
    var saved = root.results.length > 0
    root.jobState = (exitCode === 0 || saved) ? "done" : "error"
    root.pct = 100

    if (root.jobState === "done") {
      notify("low", Model.ICONS.music, "Chapters saved", Model.resultLine(root.results))
      root.url = ""
    } else {
      notify("critical", Model.ICONS.error, "Download failed",
             root.errorText || "See ~/.cache/chapterdl.log")
    }
  }

  Process {
    id: job
    stdout: SplitParser { onRead: function(line) { root.handleEvent(line) } }
    onExited: function(exitCode) { root.finish(exitCode) }
  }

  Process {
    id: clipboard
    command: ["wl-paste", "-n"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var text = String(this.text).trim()
        if (Model.looksLikeUrl(text)) root.url = text

        if (root.startWhenPasted) {
          root.startWhenPasted = false
          if (root.canStart) {
            root.start()
          } else {
            root.jobState = "error"
            root.errorText = "Nothing that looks like a link in the clipboard"
          }
        }
      }
    }
  }

  Process { id: opener }
  Process { id: notifier }

  IpcHandler {
    target: "kuroshi.chapterdl"

    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    // Addressable from a keybind, so a link in the clipboard can go straight to
    // disk without the panel ever being looked at.
    function cancel(): void { root.cancel() }

    function grab(): void {
      if (root.running) return
      root.errorText = ""
      root.startWhenPasted = true
      root.controller.show()
      clipboard.running = true     // regardless of autoPaste: grab *is* the paste
    }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.jobState === "error" ? Model.ICONS.error : Model.ICONS.music
    slotSize: Style.bar.iconSlot
    tooltipText: Model.tooltip(root.jobState, root.info, root.overallPct)

    onPressed: function(b) {
      if (b === Qt.MiddleButton && root.results.length) root.openFolder()
      else root.toggle()
    }

    // The bar is the only status a closed panel has, so it breathes while a
    // download is in flight -- the same pulse omarchy.power uses when charging.
    SequentialAnimation on opacity {
      running: root.running
      loops: Animation.Infinite
      alwaysRunToEnd: true
      NumberAnimation { from: 1.0; to: 0.45; duration: 900; easing.type: Easing.InOutSine }
      NumberAnimation { from: 0.45; to: 1.0; duration: 900; easing.type: Easing.InOutSine }
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(340))
    contentHeight: panel.fittedContentHeight(column.implicitHeight)

    // The URL field owns the keyboard whenever it has focus; without this the
    // catcher's j/k cursor keys would eat half the letters someone types.
    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: urlField.activeFocus
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onReturnRequested: if (root.canStart) root.start()

      Column {
        id: column
        width: parent.width
        spacing: Style.space(8)

        PanelSectionHeader {
          text: "CHAPTERS TO TRACKS"
          foreground: root.foreground
          fontFamily: root.fontFamily
        }

        TextField {
          id: urlField
          width: parent.width
          placeholderText: "Paste a link"
          foreground: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          enabled: !root.running
          text: root.url

          onTextChanged: if (text !== root.url) root.url = text
          onAccepted: if (root.canStart) root.start()
          Keys.onEscapePressed: root.close()

          // Focus follows the panel opening, so the common case is: keybind,
          // paste already done by the clipboard read, Enter.
          Connections {
            target: root
            function onOpenedChanged() {
              if (root.opened) Qt.callLater(urlField.forceActiveFocus)
            }
          }
        }

        // ---------- Actions ----------
        Row {
          width: parent.width
          spacing: Style.spacing.controlGap

          Button {
            id: goButton
            text: root.running ? "Cancel" : "Download"
            iconText: root.running ? "" : Model.ICONS.download
            foreground: root.foreground
            fontFamily: root.fontFamily
            bordered: true
            enabled: root.running || root.canStart
            opacity: enabled ? 1 : 0.45
            onClicked: root.running ? root.cancel() : root.start()
          }

          Button {
            visible: root.results.length > 0 && !root.running
            text: "Open folder"
            iconText: Model.ICONS.folder
            foreground: root.foreground
            fontFamily: root.fontFamily
            bordered: true
            onClicked: root.openFolder()
          }
        }

        PanelSeparator {
          visible: root.jobState !== "idle"
          foreground: root.foreground
        }

        // ---------- Status ----------
        Column {
          visible: root.jobState !== "idle"
          width: parent.width
          spacing: Style.spacing.labelGap

          Text {
            width: parent.width
            text: root.running ? Model.stageLabel(root.stage)
                 : (root.jobState === "error" ? "Failed" : Model.resultLine(root.results))
            color: root.jobState === "error" ? Color.urgent : root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            font.bold: true
            elide: Text.ElideRight
          }

          Text {
            visible: text !== ""
            width: parent.width
            text: root.jobState === "error" ? root.errorText : Model.subjectLine(root.info)
            color: root.foreground
            opacity: 0.6
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
          }

          // The chapter count is the moment the panel earns its keep: it is the
          // difference between "downloading something" and "this is 15 songs".
          Text {
            visible: root.running && root.info !== null
            width: parent.width
            text: Model.chapterLine(root.info)
            color: root.foreground
            opacity: 0.6
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
          }
        }

        // ---------- Progress ----------
        Item {
          visible: root.running
          width: parent.width
          implicitHeight: Style.space(6)

          Rectangle {
            id: track
            anchors.fill: parent
            radius: height / 2
            color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.12)
          }

          Rectangle {
            anchors.left: track.left
            anchors.verticalCenter: track.verticalCenter
            height: track.height
            radius: track.radius
            color: Color.accent
            width: Math.max(track.height, track.width * root.overallPct / 100)

            Behavior on width { NumberAnimation { duration: 240; easing.type: Easing.OutCubic } }
          }
        }

        // ---------- Tracks as they land ----------
        // Capped, because a long album would push the panel off the screen and
        // the interesting end of the list is the newest arrival anyway.
        Column {
          id: trackList
          readonly property int maxRows: 8
          readonly property int hidden: Math.max(0, root.tracks.length - maxRows)
          readonly property var shown: root.tracks.slice(hidden)

          visible: root.tracks.length > 0
          width: parent.width
          spacing: Style.spacing.labelGap

          Text {
            visible: trackList.hidden > 0
            width: parent.width
            text: "+ " + trackList.hidden + " more"
            color: root.foreground
            opacity: 0.4
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
          }

          Repeater {
            model: trackList.shown

            Text {
              required property var modelData
              width: trackList.width
              text: Model.trackLabel(modelData)
              color: root.foreground
              opacity: 0.75
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              elide: Text.ElideRight
            }
          }
        }
      }
    }
  }
}
