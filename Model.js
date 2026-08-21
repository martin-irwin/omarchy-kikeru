// Pure logic for kuroshi.kikeru: parsing the backend's line protocol and
// turning job state into the strings the panel renders. Nothing in here touches
// Qt, so `node model-test.js` can exercise all of it.

var ICONS = {
  music: "\u{F0388}",
  download: "\u{F01DA}",
  folder: "\u{F0770}",
  error: "\u{F1094}",
  remove: "\u{F0156}"
}

var STAGES = {
  probing: "Reading the link",
  downloading: "Downloading audio",
  converting: "Converting",
  splitting: "Splitting chapters",
  tagging: "Tagging tracks"
}

// yt-dlp reports "Unknown" (and sometimes "Unknown B/s" or "--:--") until it has
// enough of a download to estimate from. None of that is worth showing.
function cleanStat(text) {
  var s = String(text == null ? "" : text).trim()
  if (!s || /unknown|^-+:?-*$|^N\/?A$/i.test(s)) return ""
  return s
}

// One backend line: "<kind>\t<payload>". Payloads for info/done are JSON; the
// rest are plain. Returns null for anything malformed so a stray line of noise
// on stdout can never take the panel down.
function parseEvent(line) {
  var text = String(line == null ? "" : line)
  var tab = text.indexOf("\t")
  if (tab < 0) return null

  var kind = text.substring(0, tab)
  var raw = text.substring(tab + 1)

  if (kind === "info" || kind === "done") {
    try {
      return { kind: kind, value: JSON.parse(raw) }
    } catch (e) {
      return null
    }
  }
  // "<percent>\t<speed>\t<eta>". Speed and ETA are yt-dlp's own strings and are
  // frequently "Unknown" early in a download, so they stay optional -- the
  // percent is the only field the panel insists on.
  if (kind === "progress") {
    var fields = raw.split("\t")
    var pct = parseFloat(fields[0])
    if (!isFinite(pct)) return null
    return {
      kind: kind,
      value: {
        pct: Math.max(0, Math.min(100, pct)),
        speed: cleanStat(fields[1]),
        eta: cleanStat(fields[2])
      }
    }
  }
  if (kind === "stage" || kind === "track" || kind === "error") {
    return { kind: kind, value: raw }
  }
  return null
}

function stageLabel(stage) {
  return STAGES[stage] || "Working"
}

// Cheap enough to run on every keystroke, and the only thing standing between
// the download button and someone's clipboard full of prose.
function looksLikeUrl(text) {
  var s = String(text == null ? "" : text).trim()
  if (!/^https?:\/\/\S+$/.test(s)) return false
  return !/\s/.test(s)
}

// Percent across a whole playlist run. Each video is an equal slice regardless
// of length -- we cannot know the byte totals up front, and a bar that advances
// steadily beats one that is accurate but jumps.
function overallProgress(index, count, pct) {
  var n = Math.max(1, Number(count) || 1)
  var i = Math.max(1, Math.min(n, Number(index) || 1))
  var p = Math.max(0, Math.min(100, Number(pct) || 0))
  return ((i - 1) + p / 100) / n * 100
}

// The line under the progress bar. Names what is being worked on rather than
// repeating the stage, which the bar's own label already carries.
function subjectLine(info) {
  if (!info) return ""
  var artist = String(info.artist || "").trim()
  var album = String(info.album || "").trim()
  var name = artist && album ? artist + " — " + album : (album || artist)

  var count = Number(info.count) || 1
  if (count > 1) name = "[" + info.index + "/" + count + "] " + name
  return name
}

// What the panel says once a link has been read but before anything lands on
// disk -- the one moment where the chapter count is news.
function chapterLine(info) {
  if (!info) return ""
  var n = Number(info.chapters) || 0
  if (n <= 0) return "No chapters — saving as a single track"
  return n + " chapter" + (n === 1 ? "" : "s") + " → " + n + " track" + (n === 1 ? "" : "s")
}

// Trailing summary for a finished run. Plural agreement matters here because
// this is the line someone reads to confirm the thing actually worked.
function resultLine(results) {
  var list = results || []
  if (!list.length) return ""

  var tracks = 0
  for (var i = 0; i < list.length; i++) tracks += Number(list[i].tracks) || 0

  var albums = list.length
  var t = tracks + " track" + (tracks === 1 ? "" : "s")
  if (albums === 1) return "Saved " + t
  return "Saved " + t + " across " + albums + " albums"
}

// Track filenames arrive as "01 - So What.mp3"; the extension is noise in a
// list where every row shares it.
function trackLabel(name) {
  return String(name || "").replace(/\.[a-z0-9]{1,5}$/i, "")
}

// The line under the active job: percent always, speed and ETA only once yt-dlp
// has something real to say about them.
function progressLine(pct, speed, eta) {
  var parts = [Math.round(Number(pct) || 0) + "%"]
  var s = cleanStat(speed)
  var e = cleanStat(eta)
  if (s) parts.push(s)
  if (e) parts.push("ETA " + e)
  return parts.join(" · ")
}

// Panel header. States what is happening to the whole queue in one line, which
// is the thing someone re-opening the panel actually wants to know.
function headerStatus(state, stage, waiting) {
  var n = Math.max(0, Number(waiting) || 0)
  var tail = n > 0 ? ", " + n + " waiting" : ""

  if (state === "running") return stageLabel(stage) + tail
  if (state === "error") return "Failed" + tail
  if (n > 0) return n + " queued"
  return "Chapters to tracks"
}

// Queue rows show a URL, and a YouTube URL is mostly boilerplate. Keep the part
// that identifies the video and drop the rest.
function shortUrl(url) {
  var s = String(url || "").trim()
  var id = s.match(/[?&]v=([\w-]{6,})/) || s.match(/youtu\.be\/([\w-]{6,})/)
  if (id) return "youtube · " + id[1]

  var list = s.match(/[?&]list=([\w-]{6,})/)
  if (list) return "playlist · " + list[1]

  return s.replace(/^https?:\/\/(www\.)?/, "").substring(0, 42)
}

// The bar tooltip, which is the only status a collapsed panel can show.
function tooltip(state, info, pct) {
  if (state === "running") {
    var subject = subjectLine(info)
    var head = Math.round(pct) + "%"
    return subject ? head + " · " + subject : head
  }
  if (state === "error") return "Last download failed"
  return "Download chapters as tracks"
}

if (typeof module !== "undefined" && module.exports) {
  module.exports = {
    ICONS: ICONS,
    STAGES: STAGES,
    parseEvent: parseEvent,
    cleanStat: cleanStat,
    progressLine: progressLine,
    headerStatus: headerStatus,
    shortUrl: shortUrl,
    stageLabel: stageLabel,
    looksLikeUrl: looksLikeUrl,
    overallProgress: overallProgress,
    subjectLine: subjectLine,
    chapterLine: chapterLine,
    resultLine: resultLine,
    trackLabel: trackLabel,
    tooltip: tooltip
  }
}
