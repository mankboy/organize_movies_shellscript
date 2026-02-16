#!/bin/bash

# Movie Organizer & Folder Cleaner Script for macOS
# 1. Puts loose .mp4/.mkv files into their own folders
# 2. Renames folders to "Title (Year)" format
# 3. Uses Claude AI to look up years for files without parseable years
# 4. Logs skipped items to Foldersskipped.txt with full paths

# Anthropic API key - set this environment variable or replace with your key
ANTHROPIC_API_KEY="${ANTHROPIC_API_KEY:-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}"

# Use osascript to open a folder selection dialog
FOLDER=$(osascript -e 'tell application "Finder"
    activate
    set selectedFolder to choose folder with prompt "Select the folder containing your video files/folders:"
    return POSIX path of selectedFolder
end tell' 2>/dev/null)

# Check if user cancelled
if [ -z "$FOLDER" ]; then
    echo "No folder selected. Exiting."
    exit 1
fi

echo "Processing folder: $FOLDER"
echo "========================================"

# Create/clear the skipped log file
SKIP_LOG="${FOLDER}Foldersskipped.txt"
echo "Skipped Items Log - $(date)" > "$SKIP_LOG"
echo "========================================" >> "$SKIP_LOG"
echo "" >> "$SKIP_LOG"
echo "BASE PATH: $FOLDER" >> "$SKIP_LOG"
echo "" >> "$SKIP_LOG"
echo "========================================" >> "$SKIP_LOG"
echo "" >> "$SKIP_LOG"

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

    # Pattern 8: Year in square brackets at end - "Title [1959]" or "Title [50th Anniversary SE]"
    # First try to extract year from brackets
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
    
    # Find first .mp4 or .mkv file in the folder
    local video_file
    video_file=$(find "$folder" -maxdepth 1 -type f \( -iname "*.mp4" -o -iname "*.mkv" \) | head -n 1)
    
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
# PHASE 1: Process loose video files
# ========================================
echo ""
echo "PHASE 1: Processing loose video files..."
echo "----------------------------------------"

files_processed=0
files_skipped=0

# Find all .mp4 and .mkv files in the selected folder (not recursive)
while IFS= read -r -d '' filepath; do
    
    # Get just the filename
    filename=$(basename "$filepath")
    
    echo "Processing file: $filename"
    
    # Extract the name part (without extension)
    name_no_ext="${filename%.*}"
    
    # Extract title and year
    extract_title_year "$name_no_ext"

    # If regex extraction failed, try Claude AI lookup
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
    
done < <(find "$FOLDER" -maxdepth 1 -type f \( -iname "*.mp4" -o -iname "*.mkv" \) -print0)

echo "Files processed: $files_processed"
echo "Files skipped: $files_skipped"

# ========================================
# PHASE 2: Clean up folder names
# ========================================
echo ""
echo "PHASE 2: Cleaning up folder names..."
echo "----------------------------------------"

folders_renamed=0
folders_skipped=0
folders_clean=0

# Find all directories in the selected folder (not recursive, exclude hidden)
while IFS= read -r -d '' dirpath; do
    
    # Get just the folder name
    foldername=$(basename "$dirpath")
    
    echo "Processing folder: $foldername"
    
    # Skip if already in correct format "Name (YYYY)"
    if [[ $foldername =~ ^.+\ \((19|20)[0-9]{2}\)$ ]]; then
        echo "  Already in correct format. Skipping."
        echo ""
        ((folders_clean++))
        continue
    fi
    
    # First, try to extract from folder name
    extract_title_year "$foldername"
    
    # If no year found in folder name, try to get it from files inside
    if [ -z "$extracted_year" ]; then
        echo "  No year in folder name, checking contents..."
        extract_from_contents "$dirpath"
    fi

    # If still no year, try Claude AI lookup
    if [ -z "$extracted_title" ] || [ -z "$extracted_year" ]; then
        lookup_year_with_claude "$foldername"
    fi

    # If we found a title and year, process it
    if [ -n "$extracted_title" ] && [ -n "$extracted_year" ]; then
        
        # Create the new folder name
        new_foldername="${extracted_title} (${extracted_year})"
        
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
# Finalize skip log
# ========================================
total_skipped=$((files_skipped + folders_skipped))

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
# PHASE 3: Send organized files to Permute 3
# ========================================
echo ""
echo "PHASE 3: Sending video files to Permute 3..."
echo "----------------------------------------"

# Check if Permute 3 is installed
permute_path=$(mdfind "kMDItemCFBundleIdentifier == 'com.charliemonroe.Permute-3'" 2>/dev/null | head -n 1)

if [ -z "$permute_path" ]; then
    echo "  WARNING: Permute 3 not found. Skipping."
    permute_count=0
else
    # Collect all video files from organized subfolders
    video_files=()
    while IFS= read -r -d '' vfile; do
        video_files+=("$vfile")
    done < <(find "$FOLDER" -mindepth 2 -type f \( -iname "*.mp4" -o -iname "*.mkv" \) -print0)

    permute_count=${#video_files[@]}

    if [ "$permute_count" -eq 0 ]; then
        echo "  No video files found in organized folders."
    else
        echo "  Found $permute_count video file(s). Opening in Permute 3..."

        # Open files in batches to avoid argument length limits
        batch_size=20
        for ((i = 0; i < permute_count; i += batch_size)); do
            batch=("${video_files[@]:i:batch_size}")
            open -a "Permute 3" "${batch[@]}"
            # Brief pause between batches to let Permute process the additions
            if (( i + batch_size < permute_count )); then
                sleep 1
            fi
        done

        echo "  Sent $permute_count file(s) to Permute 3."
    fi
fi

echo ""
echo "----------------------------------------"
echo "SUMMARY:"
echo "  Files moved to folders: $files_processed"
echo "  Files skipped: $files_skipped"
echo "  Folders renamed: $folders_renamed"
echo "  Folders already clean: $folders_clean"
echo "  Folders skipped: $folders_skipped"
echo "  Files sent to Permute 3: $permute_count"
echo "========================================"
echo "Done!"

# Show completion dialog
osascript -e 'display notification "Movie organization complete! '"$permute_count"' files sent to Permute 3." with title "Movie Organizer"'