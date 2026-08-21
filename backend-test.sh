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
run "https://www.youtube.com/playlist?list=TEST" >/dev/null
check "files" "Fantasma/01 - Mic Check.mp3,Fantasma/02 - The Micro Disneycal World Tour.mp3,Fantasma/03 - New Music Machine.mp3,Fantasma/04 - Count Five Or Six.mp3," "$(files)"
check "tags"  "title=Mic Check,artist=Cornelius,album=Fantasma,track=1/4,title=The Micro Disneycal World Tour,artist=Cornelius,album=Fantasma,track=2/4,title=New Music Machine,artist=Cornelius,album=Fantasma,track=3/4,title=Count Five Or Six,artist=Cornelius,album=Fantasma,track=4/4," "$(tags)"

[ "$fail" = 0 ] && echo "all backend tests pass" || echo "backend tests FAILED"
exit "$fail"
