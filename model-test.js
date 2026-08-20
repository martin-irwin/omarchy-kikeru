// node model-test.js
const M = require("./Model.js")

let failures = 0
function check(name, actual, expected) {
  const a = JSON.stringify(actual), e = JSON.stringify(expected)
  if (a !== e) {
    failures++
    console.log(`FAIL ${name}\n  expected ${e}\n  actual   ${a}`)
  }
}

// ---- parseEvent
check("parses a stage line", M.parseEvent("stage\tsplitting"), { kind: "stage", value: "splitting" })
check("parses progress with speed and eta", M.parseEvent("progress\t42.3\t2.10MiB/s\t00:31"),
  { kind: "progress", value: { pct: 42.3, speed: "2.10MiB/s", eta: "00:31" } })
check("parses progress with percent alone", M.parseEvent("progress\t42.3"),
  { kind: "progress", value: { pct: 42.3, speed: "", eta: "" } })
check("clamps progress over 100", M.parseEvent("progress\t130\t\t"),
  { kind: "progress", value: { pct: 100, speed: "", eta: "" } })
check("drops yt-dlp's Unknown placeholders", M.parseEvent("progress\t5\tUnknown B/s\tUnknown"),
  { kind: "progress", value: { pct: 5, speed: "", eta: "" } })
check("parses info json", M.parseEvent('info\t{"album":"Kind of Blue","chapters":5}'),
  { kind: "info", value: { album: "Kind of Blue", chapters: 5 } })
check("parses a track line", M.parseEvent("track\t01 - So What.mp3"), { kind: "track", value: "01 - So What.mp3" })
check("keeps tabs inside an error message", M.parseEvent("error\ta\tb"), { kind: "error", value: "a\tb" })

// Malformed input must be dropped, not thrown -- yt-dlp writes to stderr, but a
// future version printing something unexpected to stdout should not break the panel.
check("rejects a line with no tab", M.parseEvent("just some noise"), null)
check("rejects broken json", M.parseEvent("info\t{not json"), null)
check("rejects an unknown kind", M.parseEvent("weird\tvalue"), null)
check("rejects non-numeric progress", M.parseEvent("progress\tabc"), null)
check("survives null", M.parseEvent(null), null)

// ---- looksLikeUrl
check("accepts an https link", M.looksLikeUrl("https://youtube.com/watch?v=x"), true)
check("accepts with surrounding space", M.looksLikeUrl("  https://youtu.be/x  "), true)
check("rejects prose", M.looksLikeUrl("check out this song"), false)
check("rejects an embedded url", M.looksLikeUrl("see https://x.com now"), false)
check("rejects empty", M.looksLikeUrl(""), false)
check("rejects a bare domain", M.looksLikeUrl("youtube.com/watch?v=x"), false)

// ---- overallProgress
check("single video tracks its own percent", M.overallProgress(1, 1, 40), 40)
check("second of four starts at 25", M.overallProgress(2, 4, 0), 25)
check("second of four halfway", M.overallProgress(2, 4, 50), 37.5)
check("last of four complete", M.overallProgress(4, 4, 100), 100)
check("guards a zero count", M.overallProgress(1, 0, 50), 50)

// ---- lines
check("subject joins artist and album", M.subjectLine({ artist: "Miles Davis", album: "Kind of Blue" }),
  "Miles Davis — Kind of Blue")
check("subject falls back to album alone", M.subjectLine({ album: "Kind of Blue" }), "Kind of Blue")
check("subject counts playlist position", M.subjectLine({ album: "A", index: 2, count: 5 }), "[2/5] A")
check("subject of nothing is empty", M.subjectLine(null), "")

check("chapter line pluralises", M.chapterLine({ chapters: 5 }), "5 chapters → 5 tracks")
check("chapter line singular", M.chapterLine({ chapters: 1 }), "1 chapter → 1 track")
check("chapter line explains the fallback", M.chapterLine({ chapters: 0 }),
  "No chapters — saving as a single track")

check("result line one album", M.resultLine([{ tracks: 12 }]), "Saved 12 tracks")
check("result line one track", M.resultLine([{ tracks: 1 }]), "Saved 1 track")
check("result line many albums", M.resultLine([{ tracks: 12 }, { tracks: 8 }]),
  "Saved 20 tracks across 2 albums")
check("result line of nothing is empty", M.resultLine([]), "")

check("track label drops the extension", M.trackLabel("01 - So What.mp3"), "01 - So What")
check("track label keeps dots in the name", M.trackLabel("01 - Dr. Feelgood.mp3"), "01 - Dr. Feelgood")

// ---- progressLine
check("progress line with everything", M.progressLine(42.3, "2.10MiB/s", "00:31"), "42% · 2.10MiB/s · ETA 00:31")
check("progress line without estimates", M.progressLine(42.3, "", ""), "42%")
check("progress line drops an unknown eta", M.progressLine(7, "1.2MiB/s", "Unknown"), "7% · 1.2MiB/s")

// ---- headerStatus
check("header while downloading alone", M.headerStatus("running", "downloading", 0), "Downloading audio")
check("header while downloading with a queue", M.headerStatus("running", "downloading", 2),
  "Downloading audio, 2 waiting")
check("header when idle with a queue", M.headerStatus("idle", "", 3), "3 queued")
check("header when idle and empty", M.headerStatus("idle", "", 0), "Chapters to tracks")
check("header on failure", M.headerStatus("error", "", 0), "Failed")

// ---- shortUrl
check("shortens a watch url", M.shortUrl("https://www.youtube.com/watch?v=b1Fo_M_tj6w"), "youtube · b1Fo_M_tj6w")
check("shortens a youtu.be url", M.shortUrl("https://youtu.be/b1Fo_M_tj6w"), "youtube · b1Fo_M_tj6w")
check("labels a playlist url", M.shortUrl("https://www.youtube.com/playlist?list=PLbpi6ZahtOH6"),
  "playlist · PLbpi6ZahtOH6")
check("falls back to a trimmed host", M.shortUrl("https://vimeo.com/12345"), "vimeo.com/12345")

check("tooltip while running", M.tooltip("running", { album: "A" }, 42), "42% · A")
check("tooltip when idle", M.tooltip("idle", null, 0), "Download chapters as tracks")

console.log(failures === 0 ? "all model tests pass" : `${failures} failing`)
process.exit(failures === 0 ? 0 : 1)
