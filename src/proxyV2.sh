#!/bin/bash

trap 'rm -f "$partial" 2>/dev/null' EXIT

CACHE_ROOT="/mnt/proxy-cache"
CACHE_SIZE=$((512*1024*1024)) 

urldecode() {
    local url_encoded="${1//+/ }"
    printf '%b' "${url_encoded//%/\\x}"
}

current_cache_size(){
    du -sb "$CACHE_ROOT" 2>/dev/null | awk '{print $1}'
}

make_room_cache() {
    local protected="$1"
    local current_size
    current_size=$(current_cache_size)

    if [ "$current_size" -le "$CACHE_SIZE" ]; then return 0; fi

    find "$CACHE_ROOT" -mindepth 1 -maxdepth 1 -type d -printf '%A@ %p\n' | \
    sort -n | cut -d' ' -f2- | while read -r dir_to_delete; do
        
        [ "$dir_to_delete" = "$protected" ] && continue

        rm -rf "$dir_to_delete"

        current_size=$(current_cache_size)
        [ "$current_size" -le "$CACHE_SIZE" ] && break
    done
}

prefetch_assets() {
  local url="$1"
  local dir="$2"
  local html_file="$3"

  local mark="$dir/.prefetched_assets_at"
  
  if [ -e "$mark" ] && [ $(( $(date +%s) - $(stat -c %Y "$mark" 2>/dev/null || echo 0) )) -lt 1800 ]; then
    return 0
  fi

  local total; total=$(current_cache_size)
  [ "$total" -gt $((CACHE_SIZE - 50*1024*1024)) ] && return 0

  (
    exec 8>"$dir/.prefetch_assets.lock"
    flock -n 8 || exit 0
    
    mkdir -p "$dir/assets" || exit 0

    local domain; domain=$(echo "$url" | awk -F/ '{print $1"//"$3}')
    local base; base="${url%/*}/"

    grep -oE '(src|href)="[^"]+\.(jpg|jpeg|png|gif|css|js|svg|woff|woff2|ttf|ico)"' "$html_file" | \
    cut -d'"' -f2 | \
    sort -u | \
    while read -r asset_path; do
        if [[ "$asset_path" == //* ]]; then
            echo "https:$asset_path"
        elif [[ "$asset_path" == /* ]]; then
             echo "${domain}${asset_path}"
        elif [[ "$asset_path" == http* ]]; then
             echo "$asset_path"
        else
             echo "${base}${asset_path}"
        fi
    done | \
    aria2c -i - \
      --dir="$dir/assets" \
      --j=16 \
      --quiet=true \
      --connect-timeout=5 \
      --timeout=10 \
      --auto-file-renaming=false \
      --allow-overwrite=false \
      --user-agent="Mozilla/5.0 (Compatible; AriaCache/1.0)" >/dev/null 2>&1

    date +%s > "$mark"
  ) &
}


raw_url=$(echo "$QUERY_STRING" | grep -oE 'url=[^&]+' | cut -d= -f2-)
url=$(urldecode "$raw_url")

if [ -z "$url" ]; then
    echo "Content-Type: text/html"
    echo ""
    echo "<p>Error: Missing URL parameter.</p>"
    exit 0
fi

if [[ ! "$url" =~ ^https?:// ]]; then
    echo "Content-Type: text/html"
    echo ""
    echo "<p>Error: Only HTTP/HTTPS allowed.</p>"
    exit 0
fi

hashed_url=$(printf "%s" "$url" | sha256sum | awk '{print $1}')
dir="$CACHE_ROOT/$hashed_url"

mkdir -p "$dir"
partial="$dir/.part.$$.tmp"
final="$dir/main.html"
meta_type="$dir/content-type.txt"
lock="$dir/.lock"

if [ -s "$final" ]; then
    touch -a "$dir" "$final" 2>/dev/null
    
    c_type="text/html"
    [ -f "$meta_type" ] && c_type=$(cat "$meta_type")
    
    echo "Content-Type: $c_type"
    echo "X-Cache: HIT"
    echo ""
    cat "$final"
    exit 0
fi

exec 3>"$lock"

if flock -n 3; then
    
    make_room_cache "$dir"

    if wget --quiet \
            --tries=3 \
            --timeout=15 \
            --save-headers \
            --output-document="$partial" \
            -- "$url"; then
        
        grep -i "^Content-Type:" "$partial" | head -n 1 | cut -d: -f2- | tr -d '\r' | xargs > "$meta_type"
        
        sed '1,/^\r$/d' "$partial" > "$final"
        
        c_type=$(cat "$meta_type")
        [ -z "$c_type" ] && c_type="text/html"
        
        echo "Content-Type: $c_type"
        echo "X-Cache: MISS"
        echo ""
        cat "$final"
        
        rm -f "$partial"
        
        prefetch_assets "$url" "$dir" "$final"
    else
        echo "Content-Type: text/html"
        echo ""
        echo "<p>Error: Remote server timeout or 404.</p>"
        rm -f "$partial" "$meta_type" 2>/dev/null
    fi
else
    inotifywait -q -e close_write --timeout 15 "$dir" >/dev/null 2>&1
    
    if [ -s "$final" ]; then
        touch -a "$dir" "$final" 2>/dev/null
        c_type="text/html"
        [ -f "$meta_type" ] && c_type=$(cat "$meta_type")
        
        echo "Content-Type: $c_type"
        echo "X-Cache: HIT-WAIT"
        echo ""
        cat "$final"
    else 
        echo "Content-Type: text/html"
        echo ""
        echo "<p>Error: Download failed.</p>"
    fi
fi
