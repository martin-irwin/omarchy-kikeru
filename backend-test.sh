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

run() { : >"$FFLOG"; rm -rf "$WORK/music"; mkdir -p "$WORK/music"
        PATH="$PWD/test:$PATH" ./kikeru --dir "$WORK/music" "$1" 2>/dev/null; }

files() { find "$WORK/music" -type f | sed "s|$WORK/music/||" | sort | tr '\n' ',' ; }
tags()  { grep -oE -- '-metadata (title|album|artist|track)=[^-]*' "$FFLOG" \
          | sed 's/-metadata //; s/[[:space:]]*$//' | tr '\n' ',' ; }

echo "chaptered video -> one folder, chapters as tracks"
run "https://www.youtube.com/watch?v=TEST" >/dev/null
check "files" "Kind of Blue/01 - So What.mp3,Kind of Blue/02 - Freddie Freeloader.mp3,Kind of Blue/03 - Blue in Green.mp3," "$(files)"
check "tags"  "title=So What,artist=Miles Davis,album=Kind of Blue,track=1/3,title=Freddie Freeloader,artist=Miles Davis,album=Kind of Blue,track=2/3,title=Blue in Green,artist=Miles Davis,album=Kind of Blue,track=3/3," "$(tags)"

echo "playlist -> one folder, videos as tracks"
out="$(run "https://www.youtube.com/playlist?list=TEST")"
# A 10-entry playlist means yt-dlp pads the index, so 08 and 09 arrive as
# strings bash printf would otherwise read as invalid octal and render "00".
check "numbering survives zero-padded indices"   "01,02,03,04,05,06,07,08,09,10,"   "$(find "$WORK/music" -type f | sed -E 's|.*/([0-9]+) - .*|\1|' | sort | tr '\n' ',')"
check "track 8 titled and numbered" "title=Free Fall,artist=Cornelius,album=Fantasma,track=8/10,"   "$(grep -oE -- '-metadata (title|album|artist|track)=[^-]*' "$FFLOG" | sed 's/-metadata //; s/[[:space:]]*$//' | grep -A3 '^title=Free Fall$' | tr '\n' ',')"
check "artist taken from entries when the playlist has none" "Cornelius"   "$(grep -oE -- '-metadata artist=[^-]*' "$FFLOG" | head -1 | sed 's/-metadata artist=//; s/[[:space:]]*$//')"
check "progress reaches the panel" "yes"   "$(printf '%s' "$out" | grep -q '^progress' && echo yes || echo no)"

[ "$fail" = 0 ] && echo "all backend tests pass" || echo "backend tests FAILED"
exit "$fail"
