#!/bin/bash

# Movie & TV Series Organizer Script for macOS
# 1. Puts loose .mp4/.mkv/.avi files into organized folders
#    - Movies → "Title (Year)" folders
#    - TV Episodes → "Series Name (Year)/Season XX/" folders
# 2. Organizes TV series folders into "Series Name (Year)/Season XX/" structure
# 3. Renames movie folders to "Title (Year)" format
# 4. Uses TMDB API to look up years, with Claude AI as fallback
# 5. Deletes junk files (screenshots, NFOs, samples) while preserving subtitles
# 6. Optionally sends .mkv files to Permute 3 or 4 for conversion
# 7. Excludes sample/small video files (< 50 MiB)
# 8. Logs skipped items to Foldersskipped.txt with full paths

VERSION="2.0.1"

# Minimum video file size (50 MiB) - smaller files are treated as samples and skipped
MIN_VIDEO_SIZE=52428800

# Script directory (for .env file management)
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Auto-load .env file if it exists (preserves keys across runs)
if [ -f "${SCRIPT_DIR}/.env" ]; then
    # shellcheck source=/dev/null
    source "${SCRIPT_DIR}/.env"
fi

# TMDB API key (free, register at https://www.themoviedb.org/settings/api)
# Loaded from .env, environment variable, or configured via GUI
TMDB_API_KEY="${TMDB_API_KEY:-}"

# Anthropic API key (optional fallback, from https://console.anthropic.com/)
# Loaded from .env, environment variable, or configured via GUI
ANTHROPIC_API_KEY="${ANTHROPIC_API_KEY:-}"

# Skip interactive GUI and setup when sourced for testing
if [ "${TESTING:-}" = "true" ]; then
    FOLDER=""
    PERMUTE_CHOICE="none"
    REPROCESS_MODE=false
    skipped_paths=()
    SKIP_LOG=""
fi

if [ "${TESTING:-}" != "true" ]; then
# ========================================
# GUI Launcher
# ========================================

# Helper to save settings to .env
save_env() {
    {
        echo "# Media Organizer - Settings"
        echo "# Auto-saved by GUI. See .env.example for manual setup."
        echo ""
        echo "# TMDB API key (free, register at https://www.themoviedb.org/settings/api)"
        echo "export TMDB_API_KEY='${TMDB_API_KEY}'"
        echo ""
        echo "# Anthropic API key (optional fallback, from https://console.anthropic.com/)"
        echo "export ANTHROPIC_API_KEY='${ANTHROPIC_API_KEY}'"
        echo ""
        echo "# Last selected Permute version (none, 3, or 4)"
        echo "export PERMUTE_LAST_CHOICE='${PERMUTE_CHOICE}'"
    } > "${SCRIPT_DIR}/.env"
}

# Detect installed Permute versions
HAS_PERMUTE3=false
HAS_PERMUTE4=false
if [ -n "$(mdfind "kMDItemCFBundleIdentifier == 'com.charliemonroe.Permute-3'" 2>/dev/null | head -n 1)" ]; then
    HAS_PERMUTE3=true
fi
if [ -n "$(mdfind "kMDItemCFBundleIdentifier == 'com.charliemonroe.Permute-4'" 2>/dev/null | head -n 1)" ]; then
    HAS_PERMUTE4=true
fi

# Step 1: API Key Configuration
# Auto-skip if both keys are already set, unless SHIFT is held
show_key_dialog=true
if [ -n "$TMDB_API_KEY" ] && [ -n "$ANTHROPIC_API_KEY" ]; then
    shift_held=$(osascript -l JavaScript -e \
        'ObjC.import("Cocoa"); ($.NSEvent.modifierFlags & $.NSEventModifierFlagShift) != 0' 2>/dev/null)
    if [ "$shift_held" != "true" ]; then
        show_key_dialog=false
    fi
fi

if $show_key_dialog; then
    tmdb_status="not set"
    claude_status="not set"
    [ -n "$TMDB_API_KEY" ] && tmdb_status="configured"
    [ -n "$ANTHROPIC_API_KEY" ] && claude_status="configured"

    key_action=$(osascript -e "
    display dialog \"API Keys:
  TMDB: ${tmdb_status}
  Claude AI: ${claude_status}

Would you like to configure API keys?\" buttons {\"Cancel\", \"Configure Keys\", \"Continue\"} default button \"Continue\" with title \"Media Organizer v${VERSION}\"
    set the button_pressed to the button returned of the result
    return button_pressed
    " 2>/dev/null)

    if [ -z "$key_action" ]; then
        echo "Cancelled. Exiting."
        exit 1
    fi

    if [ "$key_action" = "Configure Keys" ]; then
        # TMDB API key dialog
        new_tmdb=$(osascript -e "
        set defaultVal to \"${TMDB_API_KEY}\"
        display dialog \"Enter your TMDB API key:
(Free, register at themoviedb.org/settings/api)\" default answer defaultVal buttons {\"Cancel\", \"OK\"} default button \"OK\" with title \"Media Organizer v${VERSION}\"
        return text returned of the result
        " 2>/dev/null)

        if [ -z "$new_tmdb" ]; then
            echo "Cancelled. Exiting."
            exit 1
        fi

        # Anthropic API key dialog
        new_anthropic=$(osascript -e "
        set defaultVal to \"${ANTHROPIC_API_KEY}\"
        display dialog \"Enter your Anthropic API key (optional):
(For Claude AI fallback, from console.anthropic.com)\" default answer defaultVal buttons {\"Skip\", \"OK\"} default button \"OK\" with title \"Media Organizer v${VERSION}\"
        set btn to button returned of the result
        if btn is \"Skip\" then
            return \"__SKIP__\"
        end if
        return text returned of the result
        " 2>/dev/null)

        # Update keys in memory
        TMDB_API_KEY="$new_tmdb"
        export TMDB_API_KEY
        if [ "$new_anthropic" != "__SKIP__" ] && [ -n "$new_anthropic" ]; then
            ANTHROPIC_API_KEY="$new_anthropic"
            export ANTHROPIC_API_KEY
        fi

        echo "API keys saved to ${SCRIPT_DIR}/.env"
    fi
fi

# Step 2: Folder Selection
FOLDER=$(osascript -e "tell application \"Finder\"
    activate
    set selectedFolder to choose folder with prompt \"Select the folder containing your video files/folders:\"
    return POSIX path of selectedFolder
end tell" 2>/dev/null)

if [ -z "$FOLDER" ]; then
    echo "No folder selected. Exiting."
    exit 1
fi

# Step 3: Permute Selection
# Load previous choice as default
PERMUTE_CHOICE="${PERMUTE_LAST_CHOICE:-none}"

if $HAS_PERMUTE3 || $HAS_PERMUTE4; then
    # Build the list of available options
    permute_options="\"No conversion\""
    $HAS_PERMUTE3 && permute_options="${permute_options}, \"Permute 3\""
    $HAS_PERMUTE4 && permute_options="${permute_options}, \"Permute 4\""

    # Determine default selection from last run
    default_item="No conversion"
    if [ "$PERMUTE_CHOICE" = "3" ] && $HAS_PERMUTE3; then
        default_item="Permute 3"
    elif [ "$PERMUTE_CHOICE" = "4" ] && $HAS_PERMUTE4; then
        default_item="Permute 4"
    fi

    permute_selection=$(osascript -e "
    choose from list {${permute_options}} with prompt \"Send .mkv files to Permute for conversion?\" with title \"Media Organizer v${VERSION}\" default items {\"${default_item}\"}
    " 2>/dev/null)

    if [ -z "$permute_selection" ] || [ "$permute_selection" = "false" ]; then
        PERMUTE_CHOICE="none"
    elif [ "$permute_selection" = "Permute 3" ]; then
        PERMUTE_CHOICE="3"
    elif [ "$permute_selection" = "Permute 4" ]; then
        PERMUTE_CHOICE="4"
    fi
fi

# Save all settings to .env
save_env

echo "Media Organizer v$VERSION"
echo "Processing folder: $FOLDER"
echo "========================================"

# Skip log file path
SKIP_LOG="${FOLDER}Foldersskipped.txt"

# ========================================
# Reprocess Mode Detection
# ========================================
# If a skip log already exists, enter reprocess mode:
# only retry the previously-skipped items instead of processing everything.
REPROCESS_MODE=false
skipped_paths=()

if [ -f "$SKIP_LOG" ]; then
    REPROCESS_MODE=true
    # Parse FULL PATH entries from existing skip log
    while IFS= read -r line; do
        if [[ $line =~ ^FULL\ PATH:\ (.+)$ ]]; then
            skipped_paths+=("${BASH_REMATCH[1]}")
        fi
    done < "$SKIP_LOG"
    echo ""
    echo "Reprocess mode: found Foldersskipped.txt"
    echo "  Retrying ${#skipped_paths[@]} previously-skipped items..."
    echo ""
fi

# Create/clear the skipped log file (fresh for this run)
echo "Skipped Items Log - $(date)" > "$SKIP_LOG"
echo "========================================" >> "$SKIP_LOG"
echo "" >> "$SKIP_LOG"
echo "BASE PATH: $FOLDER" >> "$SKIP_LOG"
echo "" >> "$SKIP_LOG"
echo "========================================" >> "$SKIP_LOG"
echo "" >> "$SKIP_LOG"

fi  # end of: if [ "${TESTING:-}" != "true" ]

# ========================================
# Helper Functions
# ========================================

# Check if a path was in the previous skip list
path_in_skip_list() {
    local check_path="$1"
    for sp in "${skipped_paths[@]}"; do
        if [ "$sp" = "$check_path" ]; then
            return 0
        fi
    done
    return 1
}

# Function to log skipped folder with contents
log_skipped_folder() {
    local folder_path="$1"
    local folder_name="$2"
    local reason="$3"

    echo "FOLDER: $folder_name" >> "$SKIP_LOG"
    echo "FULL PATH: $folder_path" >> "$SKIP_LOG"
    echo "REASON: $reason" >> "$SKIP_LOG"
    echo "CONTENTS:" >> "$SKIP_LOG"

    # List all files in the folder
    if [ -d "$folder_path" ]; then
        find "$folder_path" -maxdepth 1 -type f -exec basename {} \; | while read -r file; do
            echo "  - $file" >> "$SKIP_LOG"
        done
    fi

    echo "" >> "$SKIP_LOG"
    echo "----------------------------------------" >> "$SKIP_LOG"
    echo "" >> "$SKIP_LOG"
}

# Function to log skipped file
log_skipped_file() {
    local filepath="$1"
    local filename="$2"
    local reason="$3"

    echo "FILE: $filename" >> "$SKIP_LOG"
    echo "FULL PATH: $filepath" >> "$SKIP_LOG"
    echo "REASON: $reason" >> "$SKIP_LOG"
    echo "" >> "$SKIP_LOG"
    echo "----------------------------------------" >> "$SKIP_LOG"
    echo "" >> "$SKIP_LOG"
}

# Strip common torrent site/group prefixes from a name string
# e.g. "www.SomeSite.org - Movie Title" → "Movie Title"
#      "www SomeSite org - Movie Title" → "Movie Title"
strip_torrent_prefix() {
    local input="$1"
    local result
    # "www.Site.tld - " or "www Site tld - " (dots or spaces between parts)
    result=$(echo "$input" | sed 's/^[Ww][Ww][Ww][. ][A-Za-z0-9._-]*[. ][A-Za-z]\{2,\}[[:space:]]*[-–—][[:space:]]*//')
    # "[Site.tld] " or "[ Site.tld ] - " prefix (with optional dash/en-dash/em-dash separator)
    result=$(echo "$result" | sed 's/^\[[A-Za-z0-9._ -]*\][[:space:]]*[-–—][[:space:]]*//')
    # "[Site.tld] " prefix without dash separator
    result=$(echo "$result" | sed 's/^\[[A-Za-z0-9._ -]*\][[:space:]]*//')
    echo "$result"
}

# Sanitize a folder name for macOS Finder
# Colons show as "/" in Finder, so replace with " -"
sanitize_foldername() {
    local name="$1"
    name="${name//:/ -}"
    # Collapse any resulting double spaces
    echo "$name" | sed 's/  */ /g'
}

# Check if a video file is a sample (< 50 MiB)
is_sample_file() {
    local filepath="$1"
    local filename
    filename=$(basename "$filepath")
    local ext="${filename##*.}"
    ext=$(echo "$ext" | tr '[:upper:]' '[:lower:]')

    # Only check video files
    case "$ext" in
        mp4|mkv|avi) ;;
        *) return 1 ;;
    esac

    local file_size
    file_size=$(stat -f%z "$filepath" 2>/dev/null)
    if [ -n "$file_size" ] && [ "$file_size" -lt "$MIN_VIDEO_SIZE" ]; then
        return 0
    fi
    return 1
}

# Function to extract title and year from a name string
# Returns via global variables: extracted_title, extracted_year
extract_title_year() {
    local input="$1"
    extracted_title=""
    extracted_year=""

    # Replace dots and underscores with spaces
    local name_spaces="${input//./ }"
    name_spaces="${name_spaces//_/ }"

    # Clean up multiple spaces and trim
    name_spaces=$(echo "$name_spaces" | sed 's/[[:space:]][[:space:]]*/ /g')
    name_spaces=$(echo "$name_spaces" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')

    # Pattern 1: Year in parentheses with extra stuff inside parens - "(1984 360p re-blurip)"
    if [[ $name_spaces =~ ^(.+)[[:space:]]\(((19|20)[0-9]{2})[[:space:]].+\)$ ]]; then
        extracted_title="${BASH_REMATCH[1]}"
        extracted_year="${BASH_REMATCH[2]}"

    # Pattern 2: Year in parentheses with extra stuff after parens (with space before paren)
    elif [[ $name_spaces =~ ^(.+)[[:space:]]\(((19|20)[0-9]{2})\).+$ ]]; then
        extracted_title="${BASH_REMATCH[1]}"
        extracted_year="${BASH_REMATCH[2]}"

    # Pattern 3: Year in parentheses at end with space before paren
    elif [[ $name_spaces =~ ^(.+)[[:space:]]\(((19|20)[0-9]{2})\)$ ]]; then
        extracted_title="${BASH_REMATCH[1]}"
        extracted_year="${BASH_REMATCH[2]}"

    # Pattern 4: Year in parentheses at end WITHOUT space before paren - "Title(2019)"
    elif [[ $name_spaces =~ ^(.+)\(((19|20)[0-9]{2})\)$ ]]; then
        extracted_title="${BASH_REMATCH[1]}"
        extracted_year="${BASH_REMATCH[2]}"

    # Pattern 5: Year in parentheses WITHOUT space, with extra stuff after - "Title(2019) extra"
    elif [[ $name_spaces =~ ^(.+)\(((19|20)[0-9]{2})\).+$ ]]; then
        extracted_title="${BASH_REMATCH[1]}"
        extracted_year="${BASH_REMATCH[2]}"

    # Pattern 6: "Title Year ExtraStuff" - year followed by more content
    elif [[ $name_spaces =~ ^(.+)[[:space:]]((19|20)[0-9]{2})[[:space:]].+$ ]]; then
        extracted_title="${BASH_REMATCH[1]}"
        extracted_year="${BASH_REMATCH[2]}"

    # Pattern 7: "Title Year" - year at the end with just a space before it
    elif [[ $name_spaces =~ ^(.+)[[:space:]]((19|20)[0-9]{2})$ ]]; then
        extracted_title="${BASH_REMATCH[1]}"
        extracted_year="${BASH_REMATCH[2]}"

    # Pattern 8: Year in square brackets at end - "Title [1959]"
    elif [[ $name_spaces =~ ^(.+)[[:space:]]\[((19|20)[0-9]{2})\]$ ]]; then
        extracted_title="${BASH_REMATCH[1]}"
        extracted_year="${BASH_REMATCH[2]}"
    fi

    # Clean up title - remove trailing spaces and collapse multiple spaces
    if [ -n "$extracted_title" ]; then
        extracted_title=$(echo "$extracted_title" | sed 's/[[:space:]]*$//')
        extracted_title=$(echo "$extracted_title" | sed 's/[[:space:]][[:space:]]*/ /g')
    fi
}

# Function to get title and year from video files inside a folder
extract_from_contents() {
    local folder="$1"
    extracted_title=""
    extracted_year=""

    # Find first .mp4, .mkv, or .avi file in the folder
    local video_file
    video_file=$(find "$folder" -maxdepth 1 -type f \( -iname "*.mp4" -o -iname "*.mkv" -o -iname "*.avi" \) | head -n 1)

    if [ -n "$video_file" ]; then
        local filename
        filename=$(basename "$video_file")

        # Remove extension
        local name_no_ext="${filename%.*}"

        echo "  Parsing from file: $filename"

        # Use the same extraction logic on the filename
        extract_title_year "$name_no_ext"
    fi
}

# ========================================
# TMDB API Lookup Functions
# ========================================

# Function to look up movie year using TMDB API
# Sets extracted_title and extracted_year globals
lookup_year_with_tmdb() {
    local input="$1"
    extracted_title=""
    extracted_year=""

    if [ -z "$TMDB_API_KEY" ]; then
        echo "  (TMDB API key not set, skipping TMDB lookup)"
        return 1
    fi

    # Clean up the input - replace underscores/dots with spaces
    local clean_name="${input//./ }"
    clean_name="${clean_name//_/ }"
    clean_name=$(echo "$clean_name" | sed 's/[[:space:]][[:space:]]*/ /g; s/^[[:space:]]*//; s/[[:space:]]*$//')

    echo "  Looking up movie on TMDB: $clean_name"

    # URL-encode the query
    local encoded_query
    encoded_query=$(python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1]))" "$clean_name" 2>/dev/null)

    local response
    response=$(curl -s "https://api.themoviedb.org/3/search/movie?query=${encoded_query}&api_key=${TMDB_API_KEY}" 2>/dev/null)

    # Check if we got results
    local total_results
    total_results=$(echo "$response" | python3 -c "import sys,json; print(json.load(sys.stdin).get('total_results',0))" 2>/dev/null)

    if [ "$total_results" = "0" ] || [ -z "$total_results" ]; then
        echo "  (TMDB found no movie results)"
        return 1
    fi

    # Extract title and release_date from first result
    local tmdb_title tmdb_date
    tmdb_title=$(echo "$response" | python3 -c "import sys,json; print(json.load(sys.stdin)['results'][0]['title'])" 2>/dev/null)
    tmdb_date=$(echo "$response" | python3 -c "import sys,json; print(json.load(sys.stdin)['results'][0].get('release_date',''))" 2>/dev/null)

    if [ -z "$tmdb_title" ] || [ -z "$tmdb_date" ]; then
        echo "  (TMDB result missing title or date)"
        return 1
    fi

    # Extract year from date (format: YYYY-MM-DD)
    local tmdb_year="${tmdb_date:0:4}"

    if [[ $tmdb_year =~ ^(19|20)[0-9]{2}$ ]]; then
        extracted_title="$tmdb_title"
        extracted_year="$tmdb_year"
        echo "  TMDB identified: $extracted_title ($extracted_year)"
        return 0
    else
        echo "  (TMDB returned invalid date: $tmdb_date)"
        return 1
    fi
}

# Function to look up TV series year using TMDB API
# Sets extracted_title and extracted_year globals
lookup_series_with_tmdb() {
    local input="$1"
    extracted_title=""
    extracted_year=""

    if [ -z "$TMDB_API_KEY" ]; then
        echo "  (TMDB API key not set, skipping TMDB lookup)"
        return 1
    fi

    # Clean up the input - replace underscores/dots with spaces
    local clean_name="${input//./ }"
    clean_name="${clean_name//_/ }"
    clean_name=$(echo "$clean_name" | sed 's/[[:space:]][[:space:]]*/ /g; s/^[[:space:]]*//; s/[[:space:]]*$//')

    echo "  Looking up TV series on TMDB: $clean_name"

    # URL-encode the query
    local encoded_query
    encoded_query=$(python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1]))" "$clean_name" 2>/dev/null)

    local response
    response=$(curl -s "https://api.themoviedb.org/3/search/tv?query=${encoded_query}&api_key=${TMDB_API_KEY}" 2>/dev/null)

    # Check if we got results
    local total_results
    total_results=$(echo "$response" | python3 -c "import sys,json; print(json.load(sys.stdin).get('total_results',0))" 2>/dev/null)

    if [ "$total_results" = "0" ] || [ -z "$total_results" ]; then
        echo "  (TMDB found no TV series results)"
        return 1
    fi

    # Extract name and first_air_date from first result
    local tmdb_title tmdb_date
    tmdb_title=$(echo "$response" | python3 -c "import sys,json; print(json.load(sys.stdin)['results'][0]['name'])" 2>/dev/null)
    tmdb_date=$(echo "$response" | python3 -c "import sys,json; print(json.load(sys.stdin)['results'][0].get('first_air_date',''))" 2>/dev/null)

    if [ -z "$tmdb_title" ] || [ -z "$tmdb_date" ]; then
        echo "  (TMDB result missing title or air date)"
        return 1
    fi

    # Extract year from date (format: YYYY-MM-DD)
    local tmdb_year="${tmdb_date:0:4}"

    if [[ $tmdb_year =~ ^(19|20)[0-9]{2}$ ]]; then
        extracted_title="$tmdb_title"
        extracted_year="$tmdb_year"
        echo "  TMDB identified: $extracted_title ($extracted_year)"
        return 0
    else
        echo "  (TMDB returned invalid date: $tmdb_date)"
        return 1
    fi
}

# ========================================
# Claude AI Lookup Functions
# ========================================

# Function to look up movie year using Claude AI API
# Sets extracted_title and extracted_year globals
lookup_year_with_claude() {
    local input="$1"
    extracted_title=""
    extracted_year=""

    # Check if API key is set
    if [ -z "$ANTHROPIC_API_KEY" ]; then
        echo "  (Claude API key not set, skipping AI lookup)"
        return 1
    fi

    # Clean up the input - replace underscores/dots with spaces
    local clean_name="${input//./ }"
    clean_name="${clean_name//_/ }"
    clean_name=$(echo "$clean_name" | sed 's/[[:space:]][[:space:]]*/ /g')
    clean_name=$(echo "$clean_name" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')

    echo "  Looking up with Claude AI: $clean_name"

    # Prepare the JSON payload - escape special characters
    local escaped_name
    escaped_name=$(echo "$clean_name" | sed 's/\\/\\\\/g; s/"/\\"/g')

    local json_payload
    json_payload=$(cat <<EOF
{
    "model": "claude-sonnet-4-20250514",
    "max_tokens": 100,
    "messages": [
        {
            "role": "user",
            "content": "I have a movie file named: \"${escaped_name}\"\n\nIdentify the movie and tell me the release year. Respond with ONLY the movie title and year in this exact format:\nTITLE: Movie Name\nYEAR: YYYY\n\nIf you cannot identify the movie or are unsure, respond with:\nUNKNOWN\n\nDo not include any other text."
        }
    ]
}
EOF
)

    # Call the Claude API
    local response
    response=$(curl -s -w "\n%{http_code}" "https://api.anthropic.com/v1/messages" \
        -H "Content-Type: application/json" \
        -H "x-api-key: $ANTHROPIC_API_KEY" \
        -H "anthropic-version: 2023-06-01" \
        -d "$json_payload" 2>/dev/null)

    # Extract HTTP status code (last line)
    local http_code
    http_code=$(echo "$response" | tail -n1)

    # Extract response body (everything except last line)
    local body
    body=$(echo "$response" | sed '$d')

    # Check for HTTP errors
    if [ "$http_code" != "200" ]; then
        echo "  (Claude API error: HTTP $http_code)"
        return 1
    fi

    # Extract the text content from JSON response
    local content
    content=$(echo "$body" | grep -o '"text":"[^"]*"' | head -1 | sed 's/"text":"//;s/"$//')

    # Unescape newlines
    content=$(echo -e "$content")

    # Check for UNKNOWN response
    if echo "$content" | grep -qi "UNKNOWN"; then
        echo "  (Claude could not identify the movie)"
        return 1
    fi

    # Parse TITLE and YEAR from response
    local title_line year_line
    title_line=$(echo "$content" | grep -i "^TITLE:" | head -1)
    year_line=$(echo "$content" | grep -i "^YEAR:" | head -1)

    if [ -n "$title_line" ] && [ -n "$year_line" ]; then
        # Extract values after the colon and trim whitespace
        extracted_title=$(echo "$title_line" | sed 's/^TITLE:[[:space:]]*//')
        extracted_year=$(echo "$year_line" | sed 's/^YEAR:[[:space:]]*//')

        # Validate year format
        if [[ $extracted_year =~ ^(19|20)[0-9]{2}$ ]]; then
            echo "  Claude identified: $extracted_title ($extracted_year)"
            return 0
        else
            echo "  (Claude returned invalid year format: $extracted_year)"
            extracted_title=""
            extracted_year=""
            return 1
        fi
    fi

    echo "  (Could not parse Claude response)"
    return 1
}

# ========================================
# TV Series Functions
# ========================================

# Check if a folder name indicates a TV series
is_tv_series_folder() {
    local name="$1"
    local name_lower
    name_lower=$(echo "$name" | tr '[:upper:]' '[:lower:]')

    # "complete" in name (e.g., "Breaking Bad Complete Series")
    [[ $name_lower == *"complete"* ]] && return 0

    # "season" or "series" followed by a number
    [[ $name_lower =~ (season|series)[[:space:]]*[0-9] ]] && return 0

    # SxxExx pattern in name
    [[ $name =~ [Ss][0-9]+[Ee][0-9]+ ]] && return 0

    return 1
}

# Check if a folder has Season/Series subfolders
has_season_subfolders() {
    local folder="$1"
    while IFS= read -r -d '' sub; do
        local subname
        subname=$(basename "$sub")
        local subname_lower
        subname_lower=$(echo "$subname" | tr '[:upper:]' '[:lower:]')
        if [[ $subname_lower =~ ^(season|series)[[:space:]]*[0-9]+$ ]]; then
            return 0
        fi
    done < <(find "$folder" -maxdepth 1 -mindepth 1 -type d -print0 2>/dev/null)
    return 1
}

# Check if a folder contains video files with TV episode patterns (SxxExx)
folder_contains_tv_episodes() {
    local folder="$1"
    while IFS= read -r -d '' f; do
        local fname
        fname=$(basename "$f")
        if [[ $fname =~ [Ss][0-9]+[Ee][0-9]+ ]]; then
            return 0
        fi
    done < <(find "$folder" -maxdepth 1 -type f \( -iname "*.mp4" -o -iname "*.mkv" -o -iname "*.avi" \) -print0 2>/dev/null)
    return 1
}

# Check if a loose file is a TV series episode (SxxExx pattern)
is_tv_series_file() {
    local name="$1"
    [[ $name =~ [Ss][0-9]+[Ee][0-9]+ ]] && return 0
    return 1
}

# Extract series name and season number from a name string
# Sets globals: series_name, season_number
extract_series_info() {
    local input="$1"
    series_name=""
    season_number=""

    # Replace dots and underscores with spaces
    local name_spaces="${input//./ }"
    name_spaces="${name_spaces//_/ }"
    name_spaces=$(echo "$name_spaces" | sed 's/[[:space:]][[:space:]]*/ /g; s/^[[:space:]]*//; s/[[:space:]]*$//')

    # Pattern: "Name SxxExx..." - extract name and season from SxxExx
    if [[ $name_spaces =~ ^(.+)[[:space:]][Ss]([0-9]+)[Ee][0-9]+ ]]; then
        series_name="${BASH_REMATCH[1]}"
        local snum="${BASH_REMATCH[2]}"
        snum=$(echo "$snum" | sed 's/^0*//')
        [ -z "$snum" ] && snum=0
        season_number=$(printf "%02d" "$snum")

    # Pattern: "Name Season/Series X ..."
    elif [[ $name_spaces =~ ^(.+)[[:space:]][Ss](eason|eries)[[:space:]]*([0-9]+) ]]; then
        series_name="${BASH_REMATCH[1]}"
        season_number=$(printf "%02d" "${BASH_REMATCH[3]}")

    # Pattern: "Name Complete ..."
    elif [[ $name_spaces =~ ^(.+)[[:space:]][Cc]omplete(.*)$ ]]; then
        series_name="${BASH_REMATCH[1]}"
    fi

    # Clean up series name
    if [ -n "$series_name" ]; then
        series_name=$(echo "$series_name" | sed 's/[[:space:]]*$//; s/[[:space:]][[:space:]]*/ /g')
        # Remove year in parentheses if present (we'll add it back properly)
        series_name=$(echo "$series_name" | sed 's/[[:space:]]*([0-9][0-9][0-9][0-9])[[:space:]]*$//')
        # Remove trailing dashes
        series_name=$(echo "$series_name" | sed 's/[[:space:]]*[-–—][[:space:]]*$//')
        series_name=$(echo "$series_name" | sed 's/[[:space:]]*$//')
    fi
}

# Extract season number from a filename (for sorting episodes into seasons)
# Sets global: file_season
extract_season_from_file() {
    local filename="$1"
    file_season=""

    local name_spaces="${filename//./ }"
    name_spaces="${name_spaces//_/ }"

    if [[ $name_spaces =~ [Ss]([0-9]+)[Ee][0-9]+ ]]; then
        local snum="${BASH_REMATCH[1]}"
        snum=$(echo "$snum" | sed 's/^0*//')
        [ -z "$snum" ] && snum=0
        file_season=$(printf "%02d" "$snum")
        return 0
    fi

    return 1
}

# Normalize a season subfolder name to "Season XX" format
# Outputs the normalized name (or nothing if not a season folder)
normalize_season_name() {
    local name="$1"
    local name_lower
    name_lower=$(echo "$name" | tr '[:upper:]' '[:lower:]')

    if [[ $name_lower =~ ^(season|series)[[:space:]]*([0-9]+)$ ]]; then
        local snum="${BASH_REMATCH[2]}"
        snum=$(echo "$snum" | sed 's/^0*//')
        [ -z "$snum" ] && snum=0
        printf "Season %02d" "$snum"
    fi
}

# Normalize all season subfolders in a series directory to "Season XX" format
normalize_season_subfolders() {
    local series_path="$1"

    while IFS= read -r -d '' season_dir; do
        local season_name
        season_name=$(basename "$season_dir")
        local norm_name
        norm_name=$(normalize_season_name "$season_name")

        if [ -n "$norm_name" ] && [ "$season_name" != "$norm_name" ]; then
            local target="${series_path}/${norm_name}"
            if [ ! -d "$target" ]; then
                mv "$season_dir" "$target"
                echo "    Normalized: $season_name -> $norm_name"
            fi
        fi
    done < <(find "$series_path" -maxdepth 1 -mindepth 1 -type d -print0 2>/dev/null)
}

# Look up TV series year using Claude AI API
# Sets globals: extracted_title, extracted_year
lookup_series_with_claude() {
    local input="$1"
    extracted_title=""
    extracted_year=""

    if [ -z "$ANTHROPIC_API_KEY" ]; then
        echo "  (Claude API key not set, skipping AI lookup)"
        return 1
    fi

    local clean_name="${input//./ }"
    clean_name="${clean_name//_/ }"
    clean_name=$(echo "$clean_name" | sed 's/[[:space:]][[:space:]]*/ /g; s/^[[:space:]]*//; s/[[:space:]]*$//')

    echo "  Looking up TV series with Claude AI: $clean_name"

    local escaped_name
    escaped_name=$(echo "$clean_name" | sed 's/\\/\\\\/g; s/"/\\"/g')

    local json_payload
    json_payload=$(cat <<EOF
{
    "model": "claude-sonnet-4-20250514",
    "max_tokens": 100,
    "messages": [
        {
            "role": "user",
            "content": "I have a TV series folder/file named: \"${escaped_name}\"\n\nIdentify the TV series and tell me the year it first aired. Respond with ONLY the series title and year in this exact format:\nTITLE: Series Name\nYEAR: YYYY\n\nIf you cannot identify the series or are unsure, respond with:\nUNKNOWN\n\nDo not include any other text."
        }
    ]
}
EOF
)

    local response
    response=$(curl -s -w "\n%{http_code}" "https://api.anthropic.com/v1/messages" \
        -H "Content-Type: application/json" \
        -H "x-api-key: $ANTHROPIC_API_KEY" \
        -H "anthropic-version: 2023-06-01" \
        -d "$json_payload" 2>/dev/null)

    local http_code
    http_code=$(echo "$response" | tail -n1)
    local body
    body=$(echo "$response" | sed '$d')

    if [ "$http_code" != "200" ]; then
        echo "  (Claude API error: HTTP $http_code)"
        return 1
    fi

    local content
    content=$(echo "$body" | grep -o '"text":"[^"]*"' | head -1 | sed 's/"text":"//;s/"$//')
    content=$(echo -e "$content")

    if echo "$content" | grep -qi "UNKNOWN"; then
        echo "  (Claude could not identify the series)"
        return 1
    fi

    local title_line year_line
    title_line=$(echo "$content" | grep -i "^TITLE:" | head -1)
    year_line=$(echo "$content" | grep -i "^YEAR:" | head -1)

    if [ -n "$title_line" ] && [ -n "$year_line" ]; then
        extracted_title=$(echo "$title_line" | sed 's/^TITLE:[[:space:]]*//')
        extracted_year=$(echo "$year_line" | sed 's/^YEAR:[[:space:]]*//')

        if [[ $extracted_year =~ ^(19|20)[0-9]{2}$ ]]; then
            echo "  Claude identified: $extracted_title ($extracted_year)"
            return 0
        else
            echo "  (Claude returned invalid year format: $extracted_year)"
            extracted_title=""
            extracted_year=""
            return 1
        fi
    fi

    echo "  (Could not parse Claude response)"
    return 1
}

# Allow sourcing for testing without running main logic
if [ "${TESTING:-}" = "true" ]; then
    return 0 2>/dev/null || exit 0
fi

# ========================================
# PHASE 1: Process loose video files
# ========================================
echo ""
if $REPROCESS_MODE; then
    echo "PHASE 1: Reprocessing skipped loose video files..."
else
    echo "PHASE 1: Processing loose video files..."
fi
echo "----------------------------------------"

files_processed=0
files_skipped=0
samples_skipped=0
tv_files_processed=0

# Pre-count loose video files for progress display
if $REPROCESS_MODE; then
    total_loose_files=0
    for sp in "${skipped_paths[@]}"; do
        [ -f "$sp" ] && ((total_loose_files++))
    done
else
    total_loose_files=$(find "$FOLDER" -maxdepth 1 -type f \( -iname "*.mp4" -o -iname "*.mkv" -o -iname "*.avi" \) -print0 | tr -dc '\0' | wc -c | tr -d ' ')
fi
current_loose_file=0

# Find all .mp4, .mkv, and .avi files in the selected folder (not recursive)
while IFS= read -r -d '' filepath; do

    # In reprocess mode, only process files from the previous skip log
    if $REPROCESS_MODE; then
        path_in_skip_list "$filepath" || continue
    fi

    # Get just the filename
    filename=$(basename "$filepath")
    ((current_loose_file++))

    echo "[$current_loose_file/$total_loose_files] Processing file: $filename"

    # Check for sample files (< 50 MiB)
    if is_sample_file "$filepath"; then
        file_size_mb=$(( $(stat -f%z "$filepath") / 1048576 ))
        echo "  SAMPLE: Skipping small video file (${file_size_mb} MiB)"
        echo ""
        log_skipped_file "$filepath" "$filename" "Sample file - too small (${file_size_mb} MiB, minimum 50 MiB)"
        ((samples_skipped++))
        continue
    fi

    # Extract the name part (without extension)
    name_no_ext="${filename%.*}"

    # Check if this is a TV series episode (SxxExx pattern)
    if is_tv_series_file "$name_no_ext"; then
        echo "  Detected as TV series episode"

        # Extract series info
        extract_series_info "$name_no_ext"
        s_name="$series_name"
        s_season="$season_number"

        # Try to get the year from the series name
        s_year=""
        if [ -n "$s_name" ]; then
            extract_title_year "$s_name"
            s_year="$extracted_year"
        fi

        # If no year found, try TMDB
        if [ -z "$s_year" ] && [ -n "$s_name" ]; then
            lookup_series_with_tmdb "$s_name"
            s_year="$extracted_year"
            [ -n "$extracted_title" ] && s_name="$extracted_title"
        fi

        # If still no year, try Claude as fallback
        if [ -z "$s_year" ] && [ -n "$s_name" ]; then
            lookup_series_with_claude "$s_name"
            s_year="$extracted_year"
            [ -n "$extracted_title" ] && s_name="$extracted_title"
        fi

        if [ -n "$s_name" ] && [ -n "$s_year" ] && [ -n "$s_season" ]; then
            target_series=$(sanitize_foldername "${s_name} (${s_year})")
            target_path="${FOLDER}${target_series}/Season ${s_season}"

            mkdir -p "$target_path"
            mv "$filepath" "$target_path/"
            echo "  Moved to: $target_series/Season $s_season/"
            echo ""
            ((tv_files_processed++))
        else
            echo "  WARNING: Could not fully identify TV series. Skipping."
            echo ""
            log_skipped_file "$filepath" "$filename" "Could not identify TV series name, year, or season"
            ((files_skipped++))
        fi
        continue
    fi

    # Movie processing (existing logic)
    extract_title_year "$name_no_ext"

    # If regex extraction failed, try TMDB lookup
    if [ -z "$extracted_title" ] || [ -z "$extracted_year" ]; then
        lookup_year_with_tmdb "$name_no_ext"
    fi

    # If still no match, try Claude AI as fallback
    if [ -z "$extracted_title" ] || [ -z "$extracted_year" ]; then
        lookup_year_with_claude "$name_no_ext"
    fi

    if [ -n "$extracted_title" ] && [ -n "$extracted_year" ]; then

        # Create the folder name
        folder_name="${extracted_title} (${extracted_year})"

        # Full path for the new folder
        new_folder="${FOLDER}${folder_name}"

        # Create the folder if it doesn't exist
        if [ ! -d "$new_folder" ]; then
            mkdir -p "$new_folder"
            echo "  Created folder: $folder_name"
        else
            echo "  Folder exists: $folder_name"
        fi

        # Move the file into the folder
        mv "$filepath" "$new_folder/"
        echo "  Moved file to: $folder_name/"
        echo ""

        ((files_processed++))
    else
        echo "  WARNING: Could not extract year from filename. Skipping."
        echo ""
        log_skipped_file "$filepath" "$filename" "Could not extract year from filename"
        ((files_skipped++))
    fi

done < <(find "$FOLDER" -maxdepth 1 -type f \( -iname "*.mp4" -o -iname "*.mkv" -o -iname "*.avi" \) -print0)

echo "Movie files processed: $files_processed"
echo "TV episode files processed: $tv_files_processed"
echo "Sample files skipped: $samples_skipped"
echo "Files skipped: $files_skipped"

# ========================================
# PHASE 2: Organize TV series folders
# ========================================
echo ""
if $REPROCESS_MODE; then
    echo "PHASE 2: Reprocessing skipped TV series folders..."
else
    echo "PHASE 2: Organizing TV series folders..."
fi
echo "----------------------------------------"

tv_series_organized=0
tv_series_skipped=0
tv_series_clean=0

# Pre-count directories for progress display
if $REPROCESS_MODE; then
    total_dirs_p2=0
    for sp in "${skipped_paths[@]}"; do
        [ -d "$sp" ] && ((total_dirs_p2++))
    done
else
    total_dirs_p2=$(find "$FOLDER" -maxdepth 1 -mindepth 1 -type d ! -name ".*" -print0 | tr -dc '\0' | wc -c | tr -d ' ')
fi
current_dir_p2=0

while IFS= read -r -d '' dirpath; do

    # Skip if folder was removed during earlier processing
    [ ! -d "$dirpath" ] && continue

    # In reprocess mode, only process folders from the previous skip log
    if $REPROCESS_MODE; then
        path_in_skip_list "$dirpath" || continue
    fi

    foldername=$(basename "$dirpath")
    foldername_clean=$(strip_torrent_prefix "$foldername")
    ((current_dir_p2++))

    # Check if already in correct TV series format: "Name (Year)" with Season subfolders
    # Also require no torrent prefix was stripped (otherwise needs renaming)
    if [ "$foldername_clean" = "$foldername" ] && [[ $foldername =~ ^.+\ \((19|20)[0-9]{2}\)$ ]] && has_season_subfolders "$dirpath"; then
        echo "[$current_dir_p2/$total_dirs_p2] Processing TV series: $foldername"
        echo "  Already in correct format. Normalizing season names..."
        normalize_season_subfolders "$dirpath"
        echo ""
        ((tv_series_clean++))
        continue
    fi

    # Detect if this is a TV series folder
    is_tv=false
    has_seasons=false

    if is_tv_series_folder "$foldername"; then
        is_tv=true
    fi

    if has_season_subfolders "$dirpath"; then
        is_tv=true
        has_seasons=true
    fi

    if ! $is_tv && folder_contains_tv_episodes "$dirpath"; then
        is_tv=true
    fi

    # Skip non-TV-series folders (they'll be handled in Phase 3)
    if ! $is_tv; then
        continue
    fi

    echo "[$current_dir_p2/$total_dirs_p2] Processing TV series: $foldername"

    # Extract series info from cleaned folder name (prefix stripped)
    extract_series_info "$foldername_clean"
    s_name="$series_name"
    s_season="$season_number"

    # If no series name extracted, use cleaned folder name
    if [ -z "$s_name" ]; then
        s_name="$foldername_clean"
    fi

    # Try to get year from series name or cleaned folder name
    s_year=""
    extract_title_year "$s_name"
    s_year="$extracted_year"
    # Use cleaned title to avoid "Title 2026 (2026)" redundancy
    if [ -n "$extracted_title" ] && [ -n "$s_year" ]; then
        s_name="$extracted_title"
    fi

    if [ -z "$s_year" ]; then
        extract_title_year "$foldername_clean"
        s_year="$extracted_year"
    fi

    # If no year, try extracting from video filenames inside the folder
    if [ -z "$s_year" ]; then
        echo "  No year in folder name, checking filenames inside..."
        while IFS= read -r -d '' vf; do
            local_fname=$(basename "$vf")
            local_name="${local_fname%.*}"
            extract_title_year "$local_name"
            if [ -n "$extracted_year" ]; then
                s_year="$extracted_year"
                echo "  Found year $s_year in file: $local_fname"
                break
            fi
        done < <(find "$dirpath" -maxdepth 2 -type f \( -iname "*.mp4" -o -iname "*.mkv" -o -iname "*.avi" \) -print0 2>/dev/null)
    fi

    # If no year, try TMDB
    if [ -z "$s_year" ]; then
        lookup_series_with_tmdb "$s_name"
        s_year="$extracted_year"
        if [ -n "$extracted_title" ]; then
            s_name="$extracted_title"
        fi
    fi

    # If still no year, try Claude as fallback
    if [ -z "$s_year" ]; then
        lookup_series_with_claude "$s_name"
        s_year="$extracted_year"
        if [ -n "$extracted_title" ]; then
            s_name="$extracted_title"
        fi
    fi

    if [ -z "$s_year" ]; then
        echo "  WARNING: Could not determine year for TV series. Skipping."
        echo ""
        log_skipped_folder "$dirpath" "$foldername" "Could not determine year for TV series"
        ((tv_series_skipped++))
        continue
    fi

    # Strip any year already in s_name to avoid "Name (YYYY) (YYYY)" duplicates
    # (happens when folder is already named "Series (Year)" with loose episode files inside)
    s_name=$(echo "$s_name" | sed 's/[[:space:]]*([0-9][0-9][0-9][0-9])[[:space:]]*$//')

    target_series=$(sanitize_foldername "${s_name} (${s_year})")
    target_path="${FOLDER}${target_series}"

    echo "  Target: $target_series"

    # ---- Case A: Folder has existing season subfolders ----
    if $has_seasons || has_season_subfolders "$dirpath"; then

        if [ "$dirpath" = "$target_path" ]; then
            # Already named correctly, just normalize seasons
            normalize_season_subfolders "$target_path"
        elif [ ! -d "$target_path" ]; then
            # Rename folder to target name
            mv "$dirpath" "$target_path"
            echo "  Renamed to: $target_series"
            normalize_season_subfolders "$target_path"
        else
            # Target exists, merge season subfolders into it
            echo "  Target folder exists, merging..."
            while IFS= read -r -d '' season_dir; do
                season_name=$(basename "$season_dir")
                norm_name=$(normalize_season_name "$season_name")
                [ -z "$norm_name" ] && norm_name="$season_name"
                target_season="${target_path}/${norm_name}"
                if [ ! -d "$target_season" ]; then
                    mv "$season_dir" "$target_season"
                else
                    # Move contents into existing season folder
                    find "$season_dir" -maxdepth 1 -type f -exec mv {} "$target_season/" \;
                    find "$season_dir" -maxdepth 1 -mindepth 1 -type d -exec mv {} "$target_season/" \;
                    rmdir "$season_dir" 2>/dev/null
                fi
            done < <(find "$dirpath" -maxdepth 1 -mindepth 1 -type d -print0 2>/dev/null)
            # Move any remaining root files
            find "$dirpath" -maxdepth 1 -type f -exec mv {} "$target_path/" \;
            rmdir "$dirpath" 2>/dev/null
            normalize_season_subfolders "$target_path"
        fi

    # ---- Case B: Single season folder (e.g., "Breaking Bad Season 3") ----
    elif [ -n "$s_season" ]; then
        mkdir -p "${target_path}/Season ${s_season}"
        # Move all files from folder to season subfolder
        find "$dirpath" -maxdepth 1 -type f -exec mv {} "${target_path}/Season ${s_season}/" \;
        # Move any subdirectories too
        find "$dirpath" -maxdepth 1 -mindepth 1 -type d -exec mv {} "${target_path}/Season ${s_season}/" \;
        rmdir "$dirpath" 2>/dev/null
        echo "  Organized into: $target_series/Season $s_season/"

    # ---- Case C: Complete series or folder with TV episodes ----
    else
        mkdir -p "$target_path"
        sorted=0
        unsorted=0

        # Sort all files by season based on SxxExx pattern
        while IFS= read -r -d '' filepath; do
            fname=$(basename "$filepath")
            if extract_season_from_file "$fname"; then
                mkdir -p "${target_path}/Season ${file_season}"
                mv "$filepath" "${target_path}/Season ${file_season}/"
                ((sorted++))
            else
                # No season info - move to series root
                mv "$filepath" "${target_path}/"
                ((unsorted++))
            fi
        done < <(find "$dirpath" -maxdepth 1 -type f -print0 2>/dev/null)

        # Remove empty source folder if different from target
        if [ "$dirpath" != "$target_path" ]; then
            rmdir "$dirpath" 2>/dev/null
        fi
        echo "  Sorted $sorted files into season folders ($unsorted without season info)"
    fi

    echo ""
    ((tv_series_organized++))

done < <(find "$FOLDER" -maxdepth 1 -mindepth 1 -type d ! -name ".*" -print0)

echo "TV series organized: $tv_series_organized"
echo "TV series already clean: $tv_series_clean"
echo "TV series skipped: $tv_series_skipped"

# ========================================
# PHASE 3: Clean up movie folder names
# ========================================
echo ""
if $REPROCESS_MODE; then
    echo "PHASE 3: Reprocessing skipped movie folder names..."
else
    echo "PHASE 3: Cleaning up movie folder names..."
fi
echo "----------------------------------------"

folders_renamed=0
folders_skipped=0
folders_clean=0

# Pre-count directories for progress display
if $REPROCESS_MODE; then
    # In reprocess mode, reuse the same count from Phase 2 (same folder pool)
    total_dirs_p3=$total_dirs_p2
else
    total_dirs_p3=$(find "$FOLDER" -maxdepth 1 -mindepth 1 -type d ! -name ".*" -print0 | tr -dc '\0' | wc -c | tr -d ' ')
fi
current_dir_p3=0

# Find all directories in the selected folder (not recursive, exclude hidden)
while IFS= read -r -d '' dirpath; do

    # In reprocess mode, only process folders from the previous skip log
    if $REPROCESS_MODE; then
        path_in_skip_list "$dirpath" || continue
    fi

    # Get just the folder name
    foldername=$(basename "$dirpath")
    ((current_dir_p3++))

    echo "[$current_dir_p3/$total_dirs_p3] Processing folder: $foldername"

    # Skip TV series folders (those with Season subfolders)
    if has_season_subfolders "$dirpath"; then
        echo "  TV series folder - skipping (handled in Phase 2)."
        echo ""
        continue
    fi

    # Skip folders that match TV series name patterns
    if is_tv_series_folder "$foldername"; then
        echo "  TV series pattern detected - skipping."
        echo ""
        continue
    fi

    # Strip common torrent site prefixes (e.g. "www.SomeSite.org - ") for clean processing
    foldername_clean=$(strip_torrent_prefix "$foldername")

    # Skip if already in correct format "Name (YYYY)" AND no prefix was stripped
    # (if a prefix was stripped the folder still needs renaming even if year is present)
    if [ "$foldername_clean" = "$foldername" ] && [[ $foldername =~ ^.+\ \((19|20)[0-9]{2}\)$ ]]; then
        echo "  Already in correct format. Skipping."
        echo ""
        ((folders_clean++))
        continue
    fi

    # First, try to extract from cleaned folder name
    extract_title_year "$foldername_clean"

    # If no year found in folder name, try to get it from files inside
    if [ -z "$extracted_year" ]; then
        echo "  No year in folder name, checking contents..."
        extract_from_contents "$dirpath"
    fi

    # If still no year, try TMDB lookup
    if [ -z "$extracted_title" ] || [ -z "$extracted_year" ]; then
        lookup_year_with_tmdb "$foldername_clean"
    fi

    # If still no year, try Claude AI as fallback
    if [ -z "$extracted_title" ] || [ -z "$extracted_year" ]; then
        lookup_year_with_claude "$foldername_clean"
    fi

    # If we found a title and year, process it
    if [ -n "$extracted_title" ] && [ -n "$extracted_year" ]; then

        # Create the new folder name (sanitize colons — they show as / in Finder)
        new_foldername=$(sanitize_foldername "${extracted_title} (${extracted_year})")

        # Check if new name is same as old (after cleaning)
        if [ "$foldername" = "$new_foldername" ]; then
            echo "  Already named correctly. Skipping."
            echo ""
            ((folders_clean++))
            continue
        fi

        # Full path for the renamed folder
        new_path="${FOLDER}${new_foldername}"

        # Check if a folder with the new name already exists
        if [ -d "$new_path" ]; then
            echo "  WARNING: Target folder already exists: $new_foldername"
            echo "  Skipping to avoid overwrite."
            echo ""
            log_skipped_folder "$dirpath" "$foldername" "Target folder already exists: $new_foldername"
            ((folders_skipped++))
            continue
        fi

        # Rename the folder
        mv "$dirpath" "$new_path"
        echo "  Renamed to: $new_foldername"
        echo ""

        ((folders_renamed++))
    else
        echo "  WARNING: Could not extract year from folder name or contents. Skipping."
        echo ""
        log_skipped_folder "$dirpath" "$foldername" "Could not extract year from folder name or contents"
        ((folders_skipped++))
    fi

done < <(find "$FOLDER" -maxdepth 1 -mindepth 1 -type d ! -name ".*" -print0)

# ========================================
# PHASE 4: Clean up junk files
# ========================================
echo ""
if $REPROCESS_MODE; then
    echo "PHASE 4: Skipping junk cleanup in reprocess mode."
    echo "----------------------------------------"
    junk_deleted=0
    samples_deleted=0
else
    echo "PHASE 4: Cleaning up junk files..."
    echo "----------------------------------------"

    junk_deleted=0
    samples_deleted=0
    zero_deleted=0
    duplicates_deleted=0

    # Extensions to delete (case-insensitive) — preserves subtitles (.srt, .sub, .ass, .ssa, .vtt, .idx)
    junk_extensions="jpg|jpeg|png|bmp|gif|tif|tiff|webp|txt|nfo|info|url|html|htm|xml|exe|lnk|bat|cmd|torrent|ds_store"

    # Scan all files inside organized subfolders (mindepth 2 = inside movie/series folders only)
    while IFS= read -r -d '' junk_file; do
        filename=$(basename "$junk_file")
        ext="${filename##*.}"
        ext=$(echo "$ext" | tr '[:upper:]' '[:lower:]')

        # Delete zero-byte files
        file_size=$(stat -f%z "$junk_file" 2>/dev/null)
        if [ -n "$file_size" ] && [ "$file_size" -eq 0 ]; then
            rm "$junk_file"
            echo "  Deleted empty: $filename (0 bytes)"
            ((zero_deleted++))
            continue
        fi

        # Delete junk extensions
        if [[ $ext =~ ^($junk_extensions)$ ]]; then
            rm "$junk_file"
            echo "  Deleted: $filename"
            ((junk_deleted++))
            continue
        fi

        # Delete sample video files (< 50 MiB)
        if is_sample_file "$junk_file"; then
            file_size_mb=$(( file_size / 1048576 ))
            rm "$junk_file"
            echo "  Deleted sample: $filename (${file_size_mb} MiB)"
            ((samples_deleted++))
        fi
    done < <(find "$FOLDER" -mindepth 2 -type f -print0)

    # Delete duplicate files: pre-conversion .mkv/.avi where converted .mp4 exists
    while IFS= read -r -d '' mkv_file; do
        mp4_file="${mkv_file%.*}.mp4"
        if [ -f "$mp4_file" ]; then
            filename=$(basename "$mkv_file")
            rm "$mkv_file"
            echo "  Deleted pre-conversion: $filename (.mp4 exists)"
            ((duplicates_deleted++))
        fi
    done < <(find "$FOLDER" -mindepth 2 -type f \( -iname "*.mkv" -o -iname "*.avi" \) -print0)

    # Delete duplicate files: " - 01" suffix variants (duplicate downloads)
    while IFS= read -r -d '' dup_file; do
        filename=$(basename "$dup_file")
        dirn=$(dirname "$dup_file")
        # Extract original name by removing " - 01" before the extension
        if [[ $filename =~ ^(.+)\ -\ 0[0-9](\.[^.]+)$ ]]; then
            original="${BASH_REMATCH[1]}${BASH_REMATCH[2]}"
            if [ -f "${dirn}/${original}" ]; then
                rm "$dup_file"
                echo "  Deleted duplicate: $filename (original exists)"
                ((duplicates_deleted++))
            fi
        fi
    done < <(find "$FOLDER" -mindepth 2 -type f -name "* - 0[0-9].*" -print0)

    # Delete junk subfolders (Extras, Sample, Screenshots) unless the parent movie/series
    # is actually named that (e.g. a movie called "Extras" or "Sample")
    junk_folders_deleted=0
    junk_folder_names="Extras|Sample|Screenshots"
    while IFS= read -r -d '' junk_dir; do
        # Get the parent folder name (the movie/series folder)
        parent_name=$(basename "$(dirname "$junk_dir")")
        # Strip year suffix like "(2020)" to get the bare title for comparison
        parent_title=$(echo "$parent_name" | sed 's/ ([0-9]\{4\})$//')
        parent_title_lower=$(echo "$parent_title" | tr '[:upper:]' '[:lower:]')
        dir_basename=$(basename "$junk_dir")
        dir_basename_lower=$(echo "$dir_basename" | tr '[:upper:]' '[:lower:]')
        # Skip deletion if the parent movie/series title matches the junk folder name
        if [ "$parent_title_lower" = "$dir_basename_lower" ]; then
            echo "  Keeping subfolder: $dir_basename (parent \"$parent_name\" matches)"
            continue
        fi
        rm -rf "$junk_dir"
        echo "  Deleted junk folder: $parent_name/$dir_basename"
        ((junk_folders_deleted++))
    done < <(find "$FOLDER" -mindepth 2 -type d \( -iname "Extras" -o -iname "Sample" -o -iname "Screenshots" -o -iname "Covers" \) -print0)

    # Rename "SubFiles" and "Subtitles" subfolders to "Subs" for consistency
    subs_renamed=0
    while IFS= read -r -d '' sub_dir; do
        parent_dir=$(dirname "$sub_dir")
        target_dir="${parent_dir}/Subs"
        old_name=$(basename "$sub_dir")
        if [ -d "$target_dir" ]; then
            echo "  Skipping rename: Subs already exists in $(basename "$parent_dir")"
        else
            mv "$sub_dir" "$target_dir"
            echo "  Renamed subfolder: $(basename "$parent_dir")/$old_name → Subs"
            ((subs_renamed++))
        fi
    done < <(find "$FOLDER" -mindepth 2 -type d \( -iname "SubFiles" -o -iname "Subtitles" \) -print0)

    # Remove empty directories left behind after cleanup
    empty_dirs_deleted=0
    while IFS= read -r -d '' empty_dir; do
        rmdir "$empty_dir" 2>/dev/null && ((empty_dirs_deleted++))
    done < <(find "$FOLDER" -mindepth 2 -type d -empty -print0)

    echo "Junk files deleted: $junk_deleted"
    echo "Sample videos deleted: $samples_deleted"
    [ "$zero_deleted" -gt 0 ] && echo "Zero-byte files deleted: $zero_deleted"
    [ "$duplicates_deleted" -gt 0 ] && echo "Duplicate files deleted: $duplicates_deleted"
    [ "$junk_folders_deleted" -gt 0 ] && echo "Junk folders deleted: $junk_folders_deleted"
    [ "$subs_renamed" -gt 0 ] && echo "SubFiles folders renamed: $subs_renamed"
    [ "$empty_dirs_deleted" -gt 0 ] && echo "Empty folders removed: $empty_dirs_deleted"
fi

# ========================================
# Finalize skip log
# ========================================
total_skipped=$((files_skipped + folders_skipped + tv_series_skipped + samples_skipped))

if [ "$total_skipped" -eq 0 ]; then
    # No items skipped, remove the log file
    rm "$SKIP_LOG"
    echo ""
    echo "No items were skipped - log file not created."
else
    echo ""
    echo "Skipped items logged to: $SKIP_LOG"
fi

# ========================================
# PHASE 5: Send organized files to Permute
# ========================================
echo ""
permute_count=0

if [ "$PERMUTE_CHOICE" = "none" ]; then
    echo "PHASE 5: Video conversion skipped (not selected)."
    echo "----------------------------------------"
elif $REPROCESS_MODE; then
    echo "PHASE 5: Sending video files to Permute ${PERMUTE_CHOICE}..."
    echo "----------------------------------------"
    echo "  Skipping Permute in reprocess mode."
else
    PERMUTE_APP="Permute ${PERMUTE_CHOICE}"
    echo "PHASE 5: Sending video files to ${PERMUTE_APP}..."
    echo "----------------------------------------"

    # Collect all non-sample .mkv files from organized subfolders
    video_files=()
    while IFS= read -r -d '' vfile; do
        if ! is_sample_file "$vfile"; then
            video_files+=("$vfile")
        fi
    done < <(find "$FOLDER" -mindepth 2 -type f -iname "*.mkv" -print0)

    permute_count=${#video_files[@]}

    if [ "$permute_count" -eq 0 ]; then
        echo "  No .mkv files found in organized folders."
    else
        echo "  Found $permute_count .mkv file(s). Opening in ${PERMUTE_APP}..."

        # Open files one at a time — Permute drops files when given multiple at once
        for ((i = 0; i < permute_count; i++)); do
            filename=$(basename "${video_files[$i]}")
            echo "  [$((i + 1))/$permute_count] Sending: $filename"
            open -a "$PERMUTE_APP" "${video_files[$i]}"
            sleep 0.5
        done

        echo "  Sent $permute_count file(s) to ${PERMUTE_APP}."
    fi
fi

# ========================================
# PHASE 6: Send music folders to MusicBrainz Picard
# ========================================
echo ""
picard_count=0

picard_installed=false
if [ -n "$(mdfind "kMDItemCFBundleIdentifier == 'org.musicbrainz.Picard'" 2>/dev/null | head -n 1)" ]; then
    picard_installed=true
fi

if ! $picard_installed; then
    echo "PHASE 6: MusicBrainz Picard not installed — skipping music folders."
    echo "----------------------------------------"
elif $REPROCESS_MODE; then
    echo "PHASE 6: Skipping Picard in reprocess mode."
    echo "----------------------------------------"
else
    echo "PHASE 6: Detecting music folders for MusicBrainz Picard..."
    echo "----------------------------------------"

    # Find subfolders that contain MP3 or FLAC files (music albums)
    music_folders=()
    while IFS= read -r -d '' dirpath; do
        # Check if folder contains .mp3 or .flac files
        mp3_count=$(find "$dirpath" -maxdepth 2 -type f \( -iname "*.mp3" -o -iname "*.flac" \) 2>/dev/null | head -n 1)
        if [ -n "$mp3_count" ]; then
            music_folders+=("$dirpath")
        fi
    done < <(find "$FOLDER" -maxdepth 1 -mindepth 1 -type d -print0)

    picard_count=${#music_folders[@]}

    if [ "$picard_count" -eq 0 ]; then
        echo "  No music folders found."
    else
        echo "  Found $picard_count music folder(s). Opening in MusicBrainz Picard..."

        for ((i = 0; i < picard_count; i++)); do
            foldername=$(basename "${music_folders[$i]}")
            echo "  [$((i + 1))/$picard_count] Sending: $foldername"
            open -a "MusicBrainz Picard" "${music_folders[$i]}"
            sleep 0.5
        done

        echo "  Sent $picard_count folder(s) to MusicBrainz Picard."
    fi
fi

echo ""
echo "----------------------------------------"
echo "SUMMARY:"
echo "  Movie files organized: $files_processed"
echo "  TV episode files organized: $tv_files_processed"
echo "  TV series folders organized: $tv_series_organized"
echo "  TV series already clean: $tv_series_clean"
echo "  TV series skipped: $tv_series_skipped"
echo "  Movie folders renamed: $folders_renamed"
echo "  Movie folders already clean: $folders_clean"
echo "  Movie folders skipped: $folders_skipped"
echo "  Sample files excluded: $samples_skipped"
echo "  Junk files deleted: $junk_deleted"
echo "  Sample videos deleted: $samples_deleted"
[ "${zero_deleted:-0}" -gt 0 ] && echo "  Zero-byte files deleted: $zero_deleted"
[ "${duplicates_deleted:-0}" -gt 0 ] && echo "  Duplicate files deleted: $duplicates_deleted"
[ "${junk_folders_deleted:-0}" -gt 0 ] && echo "  Junk folders deleted: $junk_folders_deleted"
[ "${subs_renamed:-0}" -gt 0 ] && echo "  SubFiles folders renamed: $subs_renamed"
if [ "$PERMUTE_CHOICE" != "none" ]; then
    echo "  Files sent to Permute ${PERMUTE_CHOICE}: $permute_count"
fi
[ "$picard_count" -gt 0 ] && echo "  Music folders sent to Picard: $picard_count"
echo "========================================"
echo "Done!"

# Show completion dialog
permute_msg=""
if [ "$PERMUTE_CHOICE" != "none" ] && [ "$permute_count" -gt 0 ]; then
    permute_msg=" ${permute_count} files sent to Permute ${PERMUTE_CHOICE}."
fi
picard_msg=""
if [ "$picard_count" -gt 0 ]; then
    picard_msg=" ${picard_count} music folders sent to Picard."
fi
osascript -e "display notification \"Organization complete! ${files_processed} movies, ${tv_files_processed} TV episodes, ${tv_series_organized} TV series.${permute_msg}${picard_msg}\" with title \"Media Organizer\""
