#!/bin/bash

echo "Content-Type: text/html"
echo

CACHE_ROOT="/mnt/proxy-cache"
CACHE_SIZE=$((512*1024*1024))




# stack overflow win
urldecode() { : "${*//+/ }"; echo -e "${_//%/\\x}"; }

#compute html file sizes sum
current_cache_size(){

find "$CACHE_ROOT" -type f\
 ! -name '.lock'\
 ! -name '.part*'\
 -printf '%s\n' 2>/dev/null |
 awk '{s+=$1} END{print s+0}'

}

list_by_LRU()
{
  find "$CACHE_ROOT" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | while read -r d; do
   file="$d/main.html"
   if [ -e "$file" ]; then
    access_time=$(stat -c %X "$file" 2>/dev/null || echo 0)
   else
    access_time=$(stat -c %X "$d" 2>/dev/null || echo 0)
   fi
   echo "$access_time $d"

done | sort -n | awk '{print $2}'

}


make_room_cache()
{
local protected="$1"
local current_size
current_size=$(current_cache_size)

if [ "$current_size" -le "$CACHE_SIZE" ]; then return 0; fi

for current_path in $(list_by_LRU); do

    [ "$current_path" = "$protected" ] && continue

    rm -f "$current_path"/.part* "$current_path"/.lock 2>/dev/null
    rm -rf "$current_path"

    current_size=$(current_cache_size)
    [ "$current_size" -le "$CACHE_SIZE" ] && break
    done 



}

#avoid for now, needs work done
prefetch_assets() {
  local url="$1" dir="$2" final="$3"

  local mark="$dir/.prefetched_assets_at"
  if [ -e "$mark" ] && [ $(( $(date +%s) - $(stat -c %Y "$mark" 2>/dev/null || echo 0) )) -lt $((30*60)) ]; then
    return 0
  fi

  local total; total=$(current_cache_size)
  [ "$total" -gt $((CACHE_SIZE - 50*1024*1024)) ] && return 0

  (
    cd "$dir" || exit 0
    exec 8>"$dir/.prefetch_assets.lock"
    flock -n 8 || exit 0
    mkdir -p "$dir/assets" || exit 0

    if nice -n 10 nohup wget \
      --quiet \
      --page-requisites \
      --adjust-extension \
      --timestamping \
      --directory-prefix="$dir/assets" \
      --tries=1 \
      --timeout=20 \
      --dns-timeout=8 \
      --connect-timeout=8 \
      --limit-rate=200k \
      -- "$url" >/dev/null 2>&1
    then
      date +%s > "$mark"
    fi
  ) &
}
#Avoid for now



raw_url=$(echo "$QUERY_STRING" | sed -E 's/.*url=([^&]*).*/\1/')

url=$(urldecode "$raw_url")

if [ -z "$url" ]; then
    echo "<p>Missing URL!</p>"
    exit 0
fi



hashed_url=$(printf "%s" "$url"|sha256sum|awk '{print $1}')

dir="$CACHE_ROOT/$hashed_url"

mkdir -p "$dir"

partial="$dir/.part.$$.$RANDOM.html"
final="$dir/main.html"
lock="$dir/.lock"

ln -sfn "$final" "$dir/link.html"

#cache hit
if [ -s "$final" ]; then

touch -a "$final" 2>/dev/null
cat "$final"


exit 0
fi

#cache miss
exec 3>"$lock"
if flock -n 3; then

    make_room_cache "$dir"

    if wget --quiet --tries=5 --timeout=60 --dns-timeout=20 --connect-timeout=20 -O "$partial" -- "$url"; then
        mv -f "$partial" "$final"
        touch -a "$final" 2>/dev/null
        cat "$final"
        prefetch_assets "$url" "$dir" "$final"
    else
        rm -f "$partial"
        echo "<p>Timeout!</p>"
    fi
else
    inotifywait -q -e close_write --timeout 12 "$dir" >/dev/null 2>&1

    if [ -s "$final" ]; then
        touch -a "$final" 2>/dev/null
        cat "$final"
        prefetch_assets "$url" "$dir" "$final"
    else 
        echo "<p>Download did not complete!</p>"
    fi
fi