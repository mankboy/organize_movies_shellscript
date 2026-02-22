# Media Organizer Script - Documentation

## Version

2.0.1

## Overview

A macOS shell script that organizes movie and TV series files into a clean, Plex-compatible folder structure. It provides a native macOS GUI for configuration, renames folders to `Title (Year)` format, sorts TV episodes into `Series Name (Year)/Season XX/` hierarchies, optionally sends `.mkv` files to Permute 3 or 4 for conversion, and sends music folders to MusicBrainz Picard for tagging.

## Requirements

- **macOS** (uses `osascript` for GUI dialogs and notifications, `mdfind` for app detection, `stat -f%z` for file sizes)
- **Bash** 3.2+ (ships with macOS)
- **curl** and **python3** (for API calls and URL encoding)
- **TMDB API key** (free, register at https://www.themoviedb.org/settings/api)
- **Anthropic API key** (optional fallback, from https://console.anthropic.com/)
- **Permute 3 or 4** (optional) - if installed, `.mkv` files can be sent for conversion
- **MusicBrainz Picard** (optional) - if installed, music folders (MP3/FLAC) are opened for tagging

## Setup

### Option A: Configure via GUI (recommended)

Simply run the script:

```bash
bash organize_movies.sh
```

A setup GUI will appear where you can enter API keys, select the source folder, and choose conversion options. Keys are saved to `.env` automatically.

### Option B: Configure via .env file

1. Copy the environment template and add your API keys:

```bash
cp .env.example .env
```

2. Edit `.env` and fill in your keys:

```bash
export TMDB_API_KEY=your_tmdb_key_here
export ANTHROPIC_API_KEY=your_anthropic_key_here  # optional
```

3. Run the script:

```bash
source .env && bash organize_movies.sh
```

Alternatively, export the keys in your shell profile (`~/.zshrc` or `~/.bash_profile`) to make them permanent.

## How It Works

### Setup GUI

When the script launches, a sequence of native macOS dialogs guides you through setup:

1. **API Key Status** — Shows whether TMDB and Claude AI keys are configured. Click "Configure Keys" to enter or update them, or "Continue" to proceed with existing settings.
2. **Folder Selection** — Standard macOS folder picker. Select the folder containing your video files and/or movie folders.
3. **Permute Selection** — If Permute 3 or 4 is installed, choose whether to send `.mkv` files for conversion. Only installed versions are shown. Select "No conversion" to skip.

The script then processes the selected folder in four phases:

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
- Extracts year from folder name, contained filenames, TMDB lookup, or Claude AI fallback
- Skips folders already in correct format
- Skips TV series folders (handled in Phase 2)

### Phase 4: Junk File Cleanup

Scans all organized subfolders and deletes non-essential files while preserving video and subtitle files.

**Deleted:**
- Zero-byte files (any type)
- Images/screenshots: `.jpg`, `.jpeg`, `.png`, `.bmp`, `.gif`, `.tif`, `.tiff`, `.webp`
- Text/metadata: `.txt`, `.nfo`, `.info`, `.url`, `.html`, `.htm`, `.xml`
- Executables/misc: `.exe`, `.lnk`, `.bat`, `.cmd`, `.torrent`, `.ds_store`
- Sample videos: `.mp4`/`.mkv`/`.avi` files smaller than 50 MiB
- Duplicate pre-conversion files: `.mkv`/`.avi` where a converted `.mp4` with the same name exists
- Duplicate downloads: files with ` - 01` (or ` - 02`, etc.) suffix where the original exists
- Empty directories left behind after cleanup

**Preserved:**
- Full-size video files (>= 50 MiB)
- Subtitle files: `.srt`, `.sub`, `.ass`, `.ssa`, `.vtt`, `.idx`

Skipped in reprocess mode.

### Phase 5: Permute Integration

If a Permute version was selected in the setup GUI, collects all `.mkv` files from organized subfolders (excluding samples) and sends them one at a time to the selected Permute version for conversion. Skipped in reprocess mode or if "No conversion" was selected.

### Phase 6: MusicBrainz Picard Integration

If MusicBrainz Picard is installed, detects subfolders containing `.mp3` or `.flac` files (music albums) and opens them in Picard for tagging and organization. Skipped in reprocess mode or if Picard is not installed.

## Title & Year Extraction

The script uses a multi-layered approach:

1. **Regex patterns** - recognizes these filename/folder patterns:

| Pattern | Example |
|---|---|
| Year in parentheses | `Movie Title (2019)` |
| Year in parentheses with extras | `Movie Title (2019) 1080p` |
| Year in parentheses with quality info | `Movie (1984 360p re-blurip)` |
| Year without parentheses | `Movie.Title.2019.1080p.BluRay` |
| Year at end | `Movie Title 2019` |
| Year in square brackets | `Movie Title [1959]` |
| No separator before year | `Title(2019)` |

2. **TMDB API lookup** - searches The Movie Database for movies (`/search/movie`) or TV series (`/search/tv`) by name. Returns structured results with release dates.

3. **Claude AI fallback** - if TMDB fails or is not configured, sends the title to Claude AI for identification. Requires `ANTHROPIC_API_KEY`.

## Configuration

| Variable | Default | Description |
|---|---|---|
| `MIN_VIDEO_SIZE` | `52428800` (50 MiB) | Minimum video file size in bytes. Smaller files are treated as samples and skipped. |
| `TMDB_API_KEY` | *(none)* | TMDB API key for movie/TV lookups. Set via GUI, environment variable, or `.env` file. |
| `ANTHROPIC_API_KEY` | *(none)* | Anthropic API key for Claude AI fallback. Optional. Set via GUI, environment variable, or `.env` file. |

## Skip Log & Reprocess Mode

When items are skipped, a `Foldersskipped.txt` file is created in the selected folder containing:
- Skipped folder/file name and full path
- Reason for skipping
- Folder contents (for skipped folders)

If nothing is skipped, the log file is not created.

**Reprocess mode**: If the script is run on a folder that already contains a `Foldersskipped.txt`, it enters reprocess mode and only retries the previously-skipped items. Items that now succeed are removed from the skip log; items that still fail remain. This allows iterative improvement — enhance the script, re-run, and watch the skip log shrink until empty.

To force a full re-run, delete `Foldersskipped.txt` before running the script.

## Progress Display

Each phase displays `[current/total]` counters so you can track progress through large libraries. Phase 4 shows batch progress when sending files to Permute.

## Supported Video Formats

- `.mp4`
- `.mkv`
- `.avi`

## Testing

Unit tests use [bats-core](https://github.com/bats-core/bats-core) (Bash Automated Testing System).

```bash
brew install bats-core
bats tests/
```

CI runs automatically on push/PR via GitHub Actions (ShellCheck linting + bats tests).

## Version History

- **2.0.1** - Torrent prefix stripping for TV series folders. Folder name sanitization (colons replaced with dashes for Finder compatibility). Duplicate file cleanup (pre-conversion .mkv/.avi where .mp4 exists, ` - 01` suffix duplicates). Zero-byte file deletion. Empty directory cleanup. Redundant year-in-title fix for TV series. MusicBrainz Picard integration for music folders (MP3/FLAC). Permute files sent individually for reliability.
- **2.0.0** - GUI launcher with native macOS dialogs for API key management, folder selection, and Permute version choice (Permute 3, Permute 4, or none). Junk file cleanup phase (deletes screenshots, NFOs, samples; preserves subtitles). Auto-skip key dialog when keys are saved (SHIFT to override). Settings persistence across runs. CI/CD with ShellCheck linting and bats unit tests via GitHub Actions.
- **1.1.0** - TMDB API integration for movie/TV year lookups (faster, free, structured). Reprocess mode: re-running on a folder with `Foldersskipped.txt` retries only previously-skipped items. API keys moved to environment variables (`.env` file) for safe publishing. Claude AI demoted to optional fallback.
- **1.0.0** - Initial versioned release. TV series organization, Permute 4 integration, sample file filtering, Claude AI lookups, torrent prefix stripping, progress counters.
