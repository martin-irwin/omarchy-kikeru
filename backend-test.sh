#!/usr/bin/env bash
# Exercises kikeru's two album paths against stub yt-dlp/ffmpeg in test/, so the
# naming, numbering and tagging can be checked without touching the network.
#   ./backend-test.sh
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
export FFLOG="$WORK/ff.log"
fail=0

check() { # check <label> <expected> <actual>
  if [ "$2" = "$3" ]; then printf '  ok   %s\n' "$1"
  else printf '  FAIL %s\n       want: %s\n       got:  %s\n' "$1" "$2" "$3"; fail=1; fi
}

# The backend finds mb-tracklist next to itself, so the stub is staged there
# for the run and removed afterwards.
use_stub_mb() { cp test/mb-tracklist ./mb-tracklist.test && mv ./mb-tracklist ./mb-tracklist.real 2>/dev/null; mv ./mb-tracklist.test ./mb-tracklist; }
restore_mb()  { [ -f ./mb-tracklist.real ] && mv -f ./mb-tracklist.real ./mb-tracklist; }
trap restore_mb EXIT

# The MusicBrainz lookup is off for most tests: it reaches the network, and a
# real release matching a fixture album would make results depend on what is in
# the database today. The tests that exercise it stage a stub instead.
run() { local url="$1"; shift
        : >"$FFLOG"; rm -rf "$WORK/music"; mkdir -p "$WORK/music"
        PATH="$PWD/test:$PATH" ./kikeru --dir "$WORK/music" --no-official-titles "$@" "$url" 2>/dev/null; }

run_official() { local url="$1"; shift
        : >"$FFLOG"; rm -rf "$WORK/music"; mkdir -p "$WORK/music"
        PATH="$PWD/test:$PATH" ./kikeru --dir "$WORK/music" "$@" "$url" 2>/dev/null; }

files() { find "$WORK/music" -type f | sed "s|$WORK/music/||" | sort | tr '\n' ',' ; }
tags()  { grep -oE -- '-metadata (title|album|artist|track)=[^-]*' "$FFLOG" \
          | sed 's/-metadata //; s/[[:space:]]*$//' | tr '\n' ',' ; }

echo "chaptered video -> one folder, chapters as tracks"
run "https://www.youtube.com/watch?v=TEST" >/dev/null
check "numbered filenames" "Kind of Blue/01 - So What.mp3,Kind of Blue/02 - Freddie Freeloader.mp3,Kind of Blue/03 - Blue in Green.mp3," "$(files)"
check "tags"  "title=So What,artist=Miles Davis,album=Kind of Blue,track=1/3,title=Freddie Freeloader,artist=Miles Davis,album=Kind of Blue,track=2/3,title=Blue in Green,artist=Miles Davis,album=Kind of Blue,track=3/3," "$(tags)"

echo "playlist -> one folder, videos as tracks"
out="$(run "https://www.youtube.com/playlist?list=TEST")"
# A 10-entry playlist means yt-dlp pads the index, so 08 and 09 arrive as
# strings bash printf would otherwise read as invalid octal and render "00".
# Filename order is the only ordering a browser upload preserves, so the
# numbers have to survive -- and 08/09 are where zero-padded indices used to
# be read as invalid octal and collapse to "00".
check "numbered filenames, in album order" \
  "01,02,03,04,05,06,07,08,09,10," \
  "$(find "$WORK/music" -type f | sed -E 's|.*/([0-9]+) - .*|\1|' | sort | tr '\n' ',')"
check "track 8 titled and numbered" "title=Free Fall,artist=Cornelius,album=Fantasma,track=8/10,"   "$(grep -oE -- '-metadata (title|album|artist|track)=[^-]*' "$FFLOG" | sed 's/-metadata //; s/[[:space:]]*$//' | grep -A3 '^title=Free Fall$' | tr '\n' ',')"
check "artist taken from entries when the playlist has none" "Cornelius"   "$(grep -oE -- '-metadata artist=[^-]*' "$FFLOG" | head -1 | sed 's/-metadata artist=//; s/[[:space:]]*$//')"
check "progress reaches the panel" "yes"   "$(printf '%s' "$out" | grep -q '^progress' && echo yes || echo no)"

echo "--filenames title -> the number lives only in the tag"
run "https://www.youtube.com/playlist?list=TEST" --filenames title >/dev/null
check "titles only" \
  "Fantasma/Chapter 8 - Seashore and Horizon.mp3,Fantasma/Clash.mp3,Fantasma/Count Five Or Six.mp3,Fantasma/Fantasma.mp3,Fantasma/Free Fall.mp3,Fantasma/Mic Check.mp3,Fantasma/New Music Machine.mp3,Fantasma/Star Fruits Surf Rider.mp3,Fantasma/Thank You For The Music.mp3,Fantasma/The Micro Disneycal World Tour.mp3," \
  "$(files)"

echo "official tracklist is preferred over the video titles"
use_stub_mb
run_official "https://www.youtube.com/playlist?list=TEST" >/dev/null
check "official title wins" "Fantasma/07 - Chapter 8.mp3" \
  "$(find "$WORK/music" -type f -name '07 *' | sed "s|$WORK/music/||")"
run "https://www.youtube.com/playlist?list=TEST" >/dev/null
check "opt-out keeps the video title" "Fantasma/07 - Chapter 8 - Seashore and Horizon.mp3" \
  "$(find "$WORK/music" -type f -name '07 *' | sed "s|$WORK/music/||")"
restore_mb

echo "Japanese label uploads"
check "corner brackets give the song name" "サウダージ" \
  "$(PATH="$PWD/test:$PATH" bash -c 'source /dev/stdin <<<"$(sed -n "/^bracket_inner()/,/^}/p" kikeru)"; bracket_inner "ポルノグラフィティ『サウダージ』MUSIC VIDEO"')"
check "text before the bracket gives the artist" "ポルノグラフィティ" \
  "$(PATH="$PWD/test:$PATH" bash -c 'source /dev/stdin <<<"$(sed -n "/^bracket_artist()/,/^}/p" kikeru)"; bracket_artist "ポルノグラフィティ『サウダージ』MUSIC VIDEO"')"

[ "$fail" = 0 ] && echo "all backend tests pass" || echo "backend tests FAILED"
exit "$fail"
