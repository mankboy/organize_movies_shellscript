# Media Organizer Script - Documentation

## Version

1.0.0

## Overview

A macOS shell script that organizes movie and TV series files into a clean, Plex-compatible folder structure. It renames folders to `Title (Year)` format, sorts TV episodes into `Series Name (Year)/Season XX/` hierarchies, and optionally sends `.mkv` files to Permute 4 for conversion.

## Requirements

- **macOS** (uses `osascript` for folder picker and notifications, `mdfind` for app detection, `stat -f%z` for file sizes)
- **Bash** 3.2+ (ships with macOS)
- **curl** (for Claude AI API calls)
- **Anthropic API key** (set via `ANTHROPIC_API_KEY` environment variable, or hardcoded in script)
- **Permute 4** (optional) - if installed, `.mkv` files are sent for conversion

## Usage

```bash
bash organize_movies.sh
```

A macOS folder picker dialog will appear. Select the folder containing your video files and/or movie folders. The script processes everything in that folder (non-recursive for loose files, one level deep for subfolders).

## How It Works

The script runs in four phases:

### Phase 1: Loose Video Files

Finds `.mp4`, `.mkv`, and `.avi` files sitting directly in the selected folder (not inside subfolders).

- **Movies**: Extracts the title and year from the filename, creates a `Title (Year)` folder, and moves the file into it.
- **TV Episodes**: Detects `SxxExx` patterns, identifies the series name and season, creates `Series Name (Year)/Season XX/` folders, and sorts episodes accordingly.
- **Sample files**: Video files smaller than 50 MiB are skipped (configurable via `MIN_VIDEO_SIZE`).

### Phase 2: TV Series Folders

Scans existing subfolders to detect TV series by:
- Folder name containing "complete", "season", "series", or `SxxExx` patterns
- Presence of `Season XX` subfolders
- Video files inside with `SxxExx` naming

Detected series are reorganized into `Series Name (Year)/Season XX/` structure. Existing season subfolders are normalized to `Season XX` format (e.g., `series1` becomes `Season 01`).

### Phase 3: Movie Folder Cleanup

Renames movie folders to the standard `Title (Year)` format:
- Strips torrent site prefixes (e.g., `www.SomeSite.org - Movie Title` becomes `Movie Title`)
- Extracts year from folder name, contained filenames, or Claude AI lookup
- Skips folders already in correct format
- Skips TV series folders (handled in Phase 2)

### Phase 4: Permute 4 Integration

If Permute 4 is installed, collects all `.mkv` files from organized subfolders (excluding samples) and sends them to Permute 4 in batches of 20 for conversion.

## Title & Year Extraction

The script recognizes these filename/folder patterns:

| Pattern | Example |
|---|---|
| Year in parentheses | `Movie Title (2019)` |
| Year in parentheses with extras | `Movie Title (2019) 1080p` |
| Year in parentheses with quality info | `Movie (1984 360p re-blurip)` |
| Year without parentheses | `Movie.Title.2019.1080p.BluRay` |
| Year at end | `Movie Title 2019` |
| Year in square brackets | `Movie Title [1959]` |
| No separator before year | `Title(2019)` |

When pattern matching fails, the script calls the Claude AI API to identify the movie/series and its release year.

## Configuration

| Variable | Default | Description |
|---|---|---|
| `MIN_VIDEO_SIZE` | `52428800` (50 MiB) | Minimum video file size in bytes. Smaller files are treated as samples and skipped. |
| `ANTHROPIC_API_KEY` | Set in script | Anthropic API key for Claude AI lookups. Can be overridden via environment variable. |

## Skip Log

When items are skipped, a `Foldersskipped.txt` file is created in the selected folder containing:
- Skipped folder/file name and full path
- Reason for skipping
- Folder contents (for skipped folders)

If nothing is skipped, the log file is not created.

## Progress Display

Each phase displays `[current/total]` counters so you can track progress through large libraries. Phase 4 shows batch progress when sending files to Permute 4.

## Supported Video Formats

- `.mp4`
- `.mkv`
- `.avi`

## Version History

- **1.0.0** - Initial versioned release. TV series organization, Permute 4 integration, sample file filtering, Claude AI lookups, torrent prefix stripping, progress counters.
