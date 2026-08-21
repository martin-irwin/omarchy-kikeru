import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Paste a link, get an album: the panel hands URLs to the bundled `kikeru`
// script, which splits each video on its chapters and tags every piece as a
// track. Links can be stacked into a queue and are worked through one at a time.
//
// Button and popup live in this one file, with `anchorItem: button` as a direct
// binding, because that is what makes the popup open under its own button --
// assigning anchorItem imperatively across a Loader leaves it stranded mid-screen.
//
// All the real work is in `kikeru`. This file only reads its line protocol
// (see the script's header) and paints the result, which keeps the download
// logic testable from a terminal and out of the shell's event loop.
Panel {
  id: root
  moduleName: "kuroshi.kikeru"
  ipcTarget: "kuroshi.kikeru"
  manageIpc: false

  // ---- Configuration, read from this widget's shell.json entry.
  readonly property string destination: setting("destination", "music")
  readonly property string musicDir: setting("musicDir", "~/Music")
  readonly property string dropboxDir: setting("dropboxDir", "~/Dropbox/Music")
  readonly property string customDir: setting("customDir", "~/Downloads")
  readonly property string audioFormat: setting("audioFormat", "mp3")
  readonly property string audioQuality: setting("audioQuality", "320K")
  // Whether a link that references a playlist is followed at all...
  readonly property string playlistFollow: setting("playlist", "auto")
  // ...and, once followed, whether it becomes one album or one folder per video.
  readonly property string playlistGrouping: setting("playlistMode", "album")
  // Whether the track number leads the filename. It is always written to the tag.
  readonly property string trackFilenames: setting("trackFilenames", "title")
  readonly property bool smartNaming: setting("smartNaming", true) === true
  readonly property bool embedArt: setting("embedArt", true) === true
  readonly property bool notifyOnFinish: setting("notify", true) === true
  readonly property bool autoPaste: setting("autoPaste", true) === true

  // Where this run will actually write. The chips pick which of the three
  // configured paths is live rather than editing one shared path, so switching
  // to Dropbox and back does not lose the custom directory someone typed.
  readonly property string activeDir: {
    if (root.destination === "dropbox") return root.dropboxDir
    if (root.destination === "custom") return root.customDir
    return root.musicDir
  }

  // ---- Job state.
  property string jobState: "idle"     // idle | running | done | error
  property string url: ""
  property var queue: []               // URLs waiting their turn
  property string activeUrl: ""
  property string stage: ""
  property real pct: 0
  property string speed: ""
  property string eta: ""
  property var info: null
  property var tracks: []
  property var results: []             // one `done` payload per finished video
  property string errorText: ""
  property int failures: 0

  property bool startWhenPasted: false

  // A cancelled run still fires onExited; without this it would be reported as
  // a failure, notification and all.
  property bool cancelling: false

  readonly property bool running: jobState === "running"
  readonly property bool canQueue: Model.looksLikeUrl(root.url)
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

  // ---- Settings persistence. Same shape omarchy.power uses for its inline
  //      entry: rewrite the whole entry, then hand it to the shell to save.
  function saveSetting(key, value) {
    var entry = { id: root.moduleName }
    for (var k in root.settings) if (k !== "id") entry[k] = root.settings[k]
    entry[key] = value

    root.settings = entry
    if (root.bar && root.bar.shell && typeof root.bar.shell.updateEntryInline === "function")
      root.bar.shell.updateEntryInline(root.moduleName, entry)
  }

  // ---- Lifecycle.
  function open() {
    root.controller.show()
    // Only reach for the clipboard when there is nothing worth keeping on
    // screen -- re-opening mid-download must not overwrite a typed URL.
    if (root.autoPaste && root.url === "") clipboard.running = true
  }

  function close() { root.controller.hide() }
  function toggle() { root.opened ? root.close() : root.open() }

  // Adding is always safe: if nothing is running the queue drains immediately,
  // otherwise the link waits its turn. One entry point for the field, the Add
  // button and the `grab` keybind alike.
  function enqueue(link) {
    if (!Model.looksLikeUrl(link)) return false

    root.queue = root.queue.concat([String(link).trim()])
    root.url = ""
    if (!root.running) root.startNext()
    return true
  }

  function startNext() {
    if (root.running || root.queue.length === 0) return

    var next = root.queue[0]
    root.queue = root.queue.slice(1)

    root.activeUrl = next
    root.jobState = "running"
    root.stage = "probing"
    root.pct = 0
    root.speed = ""
    root.eta = ""
    root.info = null
    root.tracks = []
    root.errorText = ""

    var args = [
      root.pluginDir + "/kikeru",
      "--dir", root.activeDir,
      "--format", root.audioFormat,
      "--quality", root.audioQuality,
      "--playlist", root.playlistFollow,
      "--playlist-mode", root.playlistGrouping,
      "--filenames", root.trackFilenames
    ]
    if (!root.smartNaming) args.push("--no-smart-naming")
    if (!root.embedArt) args.push("--no-art")
    args.push("--url", next)

    job.command = args
    job.running = true
  }

  function removeQueued(index) {
    if (index < 0 || index >= root.queue.length) return
    var next = root.queue.slice()
    next.splice(index, 1)
    root.queue = next
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

  // Cancels the running download only. Anything still queued stays queued and
  // starts next -- "stop this one" and "abandon everything" are different asks.
  function cancel() {
    if (!root.running) return
    root.cancelling = true
    if (!root.killTree("TERM")) job.signal(15)
    killTimer.restart()

    root.jobState = "idle"
    root.stage = ""
    root.pct = 0
    root.speed = ""
    root.eta = ""
    root.info = null
    root.activeUrl = ""
  }

  function cancelAll() {
    root.queue = []
    root.cancel()
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

  function openFolder() {
    var dir = root.results.length ? root.results[root.results.length - 1].dir : root.activeDir
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
        root.pct = event.value.pct
        root.speed = event.value.speed
        root.eta = event.value.eta
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
      root.jobState = "idle"
      // A cancel stops the current download, not the queue behind it.
      if (root.queue.length > 0) Qt.callLater(root.startNext)
      return
    }

    if (exitCode !== 0) root.failures += 1
    root.activeUrl = ""

    // More links waiting means the run is not over -- stay in the running state
    // and keep the accumulated results so the summary covers the whole batch.
    if (root.queue.length > 0) {
      root.jobState = "idle"
      Qt.callLater(root.startNext)
      return
    }

    // The script reports per-video errors and keeps going, so a non-zero exit
    // with tracks on disk is a partial success -- say so rather than claiming
    // the whole run failed.
    var saved = root.results.length > 0
    root.jobState = (root.failures === 0 || saved) ? "done" : "error"
    root.pct = 100

    if (root.jobState === "done") {
      notify("low", Model.ICONS.music, "Album saved", Model.resultLine(root.results))
    } else {
      notify("critical", Model.ICONS.error, "Download failed",
             root.errorText || "See ~/.cache/kikeru.log")
    }
    root.failures = 0
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
          if (!root.enqueue(text)) {
            root.jobState = "error"
            root.errorText = "Nothing that looks like a link in the clipboard"
          }
        }
      }
    }
  }

  Process { id: opener }
  Process { id: notifier }
  Process { id: killer }

  IpcHandler {
    target: "kuroshi.kikeru"

    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function cancel(): void { root.cancel() }
    function cancelAll(): void { root.cancelAll() }

    // Addressable from a keybind, so a link in the clipboard can go straight to
    // the queue without the panel ever being looked at.
    function grab(): void {
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
    // Percent in the bar is the whole status when the panel is shut, and it is
    // the reason to look at the bar at all mid-download.
    text: {
      if (root.jobState === "error") return Model.ICONS.error
      if (root.running && !vertical) return Model.ICONS.music + " " + Math.round(root.overallPct) + "%"
      return Model.ICONS.music
    }
    slotSize: Style.bar.iconSlot * (root.running && !vertical ? 2 : 1)
    tooltipText: Model.tooltip(root.jobState, root.info, root.overallPct)

    onPressed: function(b) {
      if (b === Qt.MiddleButton) root.openFolder()
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
    contentWidth: panel.fittedContentWidth(Style.space(380))
    contentHeight: panel.fittedContentHeight(column.implicitHeight)

    // The URL field owns the keyboard whenever it has focus; without this the
    // catcher's j/k cursor keys would eat half the letters someone types.
    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: urlField.activeFocus || dirField.activeFocus
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onReturnRequested: root.enqueue(root.url)

      Column {
        id: column
        width: parent.width
        spacing: Style.space(8)

        // ---------- Header: what is happening, and a way to the files ----------
        Item {
          width: parent.width
          implicitHeight: Math.max(headerText.implicitHeight, folderLink.implicitHeight)

          Text {
            id: headerText
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            width: parent.width - folderLink.width - Style.space(10)
            text: Model.headerStatus(root.jobState, root.stage, root.queue.length)
            color: root.jobState === "error" ? Color.urgent : root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            font.bold: true
            elide: Text.ElideRight
          }

          Button {
            id: folderLink
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            text: "Folder"
            foreground: root.foreground
            fontFamily: root.fontFamily
            fontSize: Style.font.bodySmall
            onClicked: root.openFolder()
          }
        }

        // ---------- Link entry ----------
        Item {
          width: parent.width
          implicitHeight: urlField.implicitHeight

          TextField {
            id: urlField
            anchors.left: parent.left
            anchors.right: addButton.left
            anchors.rightMargin: Style.spacing.controlGap
            placeholderText: "Paste a link"
            foreground: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            text: root.url

            onTextChanged: if (text !== root.url) root.url = text
            onAccepted: root.enqueue(root.url)
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

          Button {
            id: addButton
            anchors.right: parent.right
            anchors.verticalCenter: urlField.verticalCenter
            text: root.running ? "Queue" : "Add"
            foreground: root.foreground
            fontFamily: root.fontFamily
            bordered: true
            enabled: root.canQueue
            opacity: enabled ? 1 : 0.45
            onClicked: root.enqueue(root.url)
          }
        }

        // ---------- Where it lands ----------
        Column {
          width: parent.width
          spacing: Style.spacing.labelGap

          ButtonGroup {
            width: parent.width
            options: [
              { value: "music", label: "Music" },
              { value: "dropbox", label: "Dropbox" },
              { value: "custom", label: "Custom" }
            ]
            value: root.destination
            foreground: root.foreground
            fontFamily: root.fontFamily
            fontSize: Style.font.bodySmall
            focusable: false
            onChanged: function(value) { root.saveSetting("destination", value) }
          }

          // Fixed destinations show their path; "Custom" makes it editable, so
          // the field is not a decoration that silently ignores typing.
          Text {
            visible: root.destination !== "custom"
            width: parent.width
            text: root.activeDir
            color: root.foreground
            opacity: 0.55
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            elide: Text.ElideMiddle
          }

          TextField {
            id: dirField
            visible: root.destination === "custom"
            width: parent.width
            placeholderText: "~/Downloads"
            foreground: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            verticalPadding: Style.spacing.controlPaddingY
            text: root.customDir

            onEditingFinished: if (text !== root.customDir) root.saveSetting("customDir", text)
            Keys.onEscapePressed: root.close()
          }
        }

        // ---------- The job in flight ----------
        PanelSeparator {
          visible: root.running || root.jobState === "done" || root.jobState === "error"
          foreground: root.foreground
        }

        Column {
          visible: root.running || root.jobState === "done" || root.jobState === "error"
          width: parent.width
          spacing: Style.spacing.labelGap

          Item {
            width: parent.width
            implicitHeight: Math.max(subjectText.implicitHeight, cancelLink.implicitHeight)

            Text {
              id: subjectText
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              width: parent.width - (cancelLink.visible ? cancelLink.width + Style.space(8) : 0)
              text: {
                if (root.jobState === "error") return root.errorText
                if (root.running) return Model.subjectLine(root.info) || Model.shortUrl(root.activeUrl)
                return Model.resultLine(root.results)
              }
              color: root.foreground
              opacity: root.jobState === "error" ? 1 : 0.75
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              elide: Text.ElideRight
            }

            Button {
              id: cancelLink
              visible: root.running
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              text: "Cancel"
              foreground: Color.urgent
              fontFamily: root.fontFamily
              fontSize: Style.font.bodySmall
              onClicked: root.cancel()
            }
          }

          Text {
            visible: root.running
            width: parent.width
            // Speed and ETA describe the *download*; once yt-dlp moves on to
            // converting and splitting they are stale numbers about a finished
            // job, so only the percent survives that transition.
            text: root.stage === "downloading"
              ? Model.progressLine(root.overallPct, root.speed, root.eta)
              : Model.progressLine(root.overallPct, "", "")
            color: root.foreground
            opacity: 0.55
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
          }

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

          // The chapter count is the moment the panel earns its keep: it is the
          // difference between "downloading something" and "this is 15 songs".
          Text {
            visible: root.running && root.info !== null
            width: parent.width
            text: Model.chapterLine(root.info)
            color: root.foreground
            opacity: 0.55
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
          }
        }

        // ---------- Tracks as they land ----------
        // Capped, because a long album would push the panel off the screen and
        // the interesting end of the list is the newest arrival anyway.
        Column {
          id: trackList
          readonly property int maxRows: 6
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

        // ---------- Waiting ----------
        PanelSeparator {
          visible: root.queue.length > 0
          foreground: root.foreground
        }

        Column {
          visible: root.queue.length > 0
          width: parent.width
          spacing: Style.spacing.labelGap

          Repeater {
            model: root.queue

            Item {
              id: queueRow
              required property var modelData
              required property int index

              width: column.width
              implicitHeight: Math.max(queueText.implicitHeight, dropButton.implicitHeight)

              Text {
                id: queueText
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                width: parent.width - dropButton.width - Style.space(8)
                text: Model.shortUrl(queueRow.modelData)
                color: root.foreground
                opacity: 0.6
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
                elide: Text.ElideRight
              }

              PanelActionButton {
                id: dropButton
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                iconText: Model.ICONS.remove
                foreground: root.foreground
                hoverColor: Color.urgent
                fontFamily: root.fontFamily
                tooltipText: "Remove from queue"
                onClicked: root.removeQueued(queueRow.index)
              }
            }
          }
        }
      }
    }
  }
}
