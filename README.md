# Media Organizer

A macOS shell script that organizes movie and TV series files into a clean, Plex-compatible folder structure with a native GUI interface.

## Features

- **Native macOS GUI** for API key management, folder selection, and conversion options
- **Smart renaming** of movie folders to `Title (Year)` format
- **TV series detection** and organization into `Series Name (Year)/Season XX/` hierarchies
- **TMDB API integration** for accurate movie/TV year lookups, with Claude AI as optional fallback
- **Junk file cleanup** removes screenshots, NFOs, zero-byte files, samples, and duplicates while preserving subtitles
- **Duplicate detection** deletes pre-conversion `.mkv`/`.avi` when `.mp4` exists, and removes ` - 01` suffix copies
- **[Permute](https://software.charliemonroe.net/permute/) integration** sends `.mkv` files for conversion (supports Permute 3 and 4)
- **[MusicBrainz Picard](https://picard.musicbrainz.org/) integration** opens music folders for tagging
- **Reprocess mode** retries previously-skipped items without re-running the entire library
- **Torrent prefix stripping** cleans up `www.Site.org - ` and `[Site]` prefixes automatically
- **Settings persistence** saves API keys and preferences across runs

## Requirements

- **macOS** (uses `osascript`, `mdfind`, `stat -f%z`)
- **Bash** 3.2+ (ships with macOS)
- **curl** and **python3** (included with macOS)
- **TMDB API key** (free — [register here](https://www.themoviedb.org/settings/api))

### Optional

- **Anthropic API key** for Claude AI fallback ([console.anthropic.com](https://console.anthropic.com/))
- **Permute 3 or 4** for `.mkv` to `.mp4` conversion
- **MusicBrainz Picard** for music folder tagging

## Quick Start

```bash
git clone https://github.com/mankboy/organize_movies_shellscript.git
cd organize_movies_shellscript
./organize_movies.sh
```

The setup GUI will walk you through entering API keys, selecting a folder, and choosing conversion options. Keys are saved to `.env` automatically for future runs.

### Alternative: Manual Setup

```bash
cp .env.example .env
# Edit .env with your API keys
./organize_movies.sh
```

## How It Works

The script processes your selected folder in six phases:

| Phase | Description |
|-------|-------------|
| **1. Loose Files** | Finds video files in the root folder, creates `Title (Year)` folders, sorts TV episodes into `Series/Season XX/` |
| **2. TV Series** | Detects and reorganizes TV series folders by name patterns, season subfolders, or episode filenames |
| **3. Movie Folders** | Renames movie folders to `Title (Year)` format, stripping torrent prefixes and quality tags |
| **4. Junk Cleanup** | Deletes screenshots, NFOs, zero-byte files, samples, duplicates, and empty directories |
| **5. Permute** | Sends `.mkv` files to Permute for conversion (if selected) |
| **6. Picard** | Opens music folders (MP3/FLAC) in MusicBrainz Picard for tagging (if installed) |

### Title & Year Extraction

The script uses a multi-layered approach to identify titles and years:

1. **Regex patterns** — handles `Movie (2019)`, `Movie.Title.2019.1080p.BluRay`, `Movie [1959]`, and more
2. **TMDB API** — searches The Movie Database for structured results with release dates
3. **Claude AI** — optional fallback for titles that TMDB can't match

### Reprocess Mode

If the script is run on a folder containing `Foldersskipped.txt` from a previous run, it enters reprocess mode — only retrying previously-skipped items. Delete the file to force a full re-run.

## Supported Formats

**Video:** `.mp4`, `.mkv`, `.avi`
**Subtitles (preserved):** `.srt`, `.sub`, `.ass`, `.ssa`, `.vtt`, `.idx`
**Music (sent to Picard):** `.mp3`, `.flac`

## Testing

```bash
brew install bats-core
bats tests/
```

CI runs automatically on push/PR via GitHub Actions (ShellCheck linting + bats unit tests on macOS).

## Version History

| Version | Highlights |
|---------|------------|
| **2.0.1** | Torrent prefix fix for TV series, folder name sanitization, duplicate/zero-byte cleanup, MusicBrainz Picard integration |
| **2.0.0** | Native macOS GUI, junk file cleanup, settings persistence, CI/CD pipeline |
| **1.1.0** | TMDB API integration, reprocess mode, `.env` key management |
| **1.0.0** | Initial release — TV series support, Permute integration, Claude AI lookups |

## License

MIT
