#!/usr/bin/env bats

# Unit tests for organize_movies.sh functions
# Run with: bats tests/test_organize.bats

setup() {
    # Source the script in testing mode to load functions without executing main logic
    export TESTING=true
    export TMDB_API_KEY=""
    export ANTHROPIC_API_KEY=""
    source "$BATS_TEST_DIRNAME/../organize_movies.sh"
}

# ========================================
# extract_title_year tests
# ========================================

@test "extract_title_year: year in parentheses" {
    extract_title_year "Movie Title (2019)"
    [ "$extracted_title" = "Movie Title" ]
    [ "$extracted_year" = "2019" ]
}

@test "extract_title_year: year in parentheses with extras after" {
    extract_title_year "Movie Title (2019) 1080p"
    [ "$extracted_title" = "Movie Title" ]
    [ "$extracted_year" = "2019" ]
}

@test "extract_title_year: year in parentheses with quality info inside" {
    extract_title_year "Movie (1984 360p re-blurip)"
    [ "$extracted_title" = "Movie" ]
    [ "$extracted_year" = "1984" ]
}

@test "extract_title_year: year without parentheses followed by extras" {
    extract_title_year "Movie Title 2019 1080p BluRay"
    [ "$extracted_title" = "Movie Title" ]
    [ "$extracted_year" = "2019" ]
}

@test "extract_title_year: year at end" {
    extract_title_year "Movie Title 2019"
    [ "$extracted_title" = "Movie Title" ]
    [ "$extracted_year" = "2019" ]
}

@test "extract_title_year: year in square brackets" {
    extract_title_year "Movie Title [1959]"
    [ "$extracted_title" = "Movie Title" ]
    [ "$extracted_year" = "1959" ]
}

@test "extract_title_year: no separator before year" {
    extract_title_year "Title(2019)"
    [ "$extracted_title" = "Title" ]
    [ "$extracted_year" = "2019" ]
}

@test "extract_title_year: dots replaced with spaces" {
    extract_title_year "Movie.Title.2019.1080p.BluRay"
    [ "$extracted_title" = "Movie Title" ]
    [ "$extracted_year" = "2019" ]
}

@test "extract_title_year: underscores replaced with spaces" {
    extract_title_year "Movie_Title_2020"
    [ "$extracted_title" = "Movie Title" ]
    [ "$extracted_year" = "2020" ]
}

@test "extract_title_year: no year found returns empty" {
    extract_title_year "Some Random Folder"
    [ -z "$extracted_title" ]
    [ -z "$extracted_year" ]
}

# ========================================
# strip_torrent_prefix tests
# ========================================

@test "strip_torrent_prefix: www.Site.org prefix with dash" {
    result=$(strip_torrent_prefix "www.SomeSite.org - Movie Title")
    [ "$result" = "Movie Title" ]
}

@test "strip_torrent_prefix: www with spaces prefix" {
    result=$(strip_torrent_prefix "www SomeSite org - Movie Title")
    [ "$result" = "Movie Title" ]
}

@test "strip_torrent_prefix: bracket prefix" {
    result=$(strip_torrent_prefix "[SomeSite.org] Movie Title")
    [ "$result" = "Movie Title" ]
}

@test "strip_torrent_prefix: no prefix unchanged" {
    result=$(strip_torrent_prefix "Movie Title (2019)")
    [ "$result" = "Movie Title (2019)" ]
}

# ========================================
# is_tv_series_folder tests
# ========================================

@test "is_tv_series_folder: complete in name" {
    is_tv_series_folder "Breaking Bad Complete Series"
}

@test "is_tv_series_folder: season followed by number" {
    is_tv_series_folder "Show Name Season 3"
}

@test "is_tv_series_folder: series followed by number" {
    is_tv_series_folder "Show Name Series 2"
}

@test "is_tv_series_folder: SxxExx pattern" {
    is_tv_series_folder "Show S01E01"
}

@test "is_tv_series_folder: movie name not detected" {
    ! is_tv_series_folder "The Avengers (2012)"
}

# ========================================
# extract_series_info tests
# ========================================

@test "extract_series_info: SxxExx pattern" {
    extract_series_info "Breaking Bad S03E05 Fly"
    [ "$series_name" = "Breaking Bad" ]
    [ "$season_number" = "03" ]
}

@test "extract_series_info: Season N pattern" {
    extract_series_info "Breaking Bad Season 3"
    [ "$series_name" = "Breaking Bad" ]
    [ "$season_number" = "03" ]
}

@test "extract_series_info: Complete pattern" {
    extract_series_info "Breaking Bad Complete"
    [ "$series_name" = "Breaking Bad" ]
    [ -z "$season_number" ]
}

@test "extract_series_info: dots in name" {
    extract_series_info "The.Walking.Dead.S05E10.720p"
    [ "$series_name" = "The Walking Dead" ]
    [ "$season_number" = "05" ]
}

# ========================================
# normalize_season_name tests
# ========================================

@test "normalize_season_name: Season 1 to Season 01" {
    result=$(normalize_season_name "Season 1")
    [ "$result" = "Season 01" ]
}

@test "normalize_season_name: season 12 to Season 12" {
    result=$(normalize_season_name "season 12")
    [ "$result" = "Season 12" ]
}

@test "normalize_season_name: Series 3 to Season 03" {
    result=$(normalize_season_name "Series 3")
    [ "$result" = "Season 03" ]
}

@test "normalize_season_name: non-season returns empty" {
    result=$(normalize_season_name "Extras")
    [ -z "$result" ]
}

# ========================================
# extract_season_from_file tests
# ========================================

@test "extract_season_from_file: standard SxxExx" {
    extract_season_from_file "show.S03E05.720p.mkv"
    [ "$file_season" = "03" ]
}

@test "extract_season_from_file: lowercase sxxexx" {
    extract_season_from_file "show.s01e01.mkv"
    [ "$file_season" = "01" ]
}

@test "extract_season_from_file: season 10+" {
    extract_season_from_file "show.S12E01.mkv"
    [ "$file_season" = "12" ]
}

@test "extract_season_from_file: no season returns failure" {
    ! extract_season_from_file "random_movie_file.mkv"
}

# ========================================
# is_tv_series_file tests
# ========================================

@test "is_tv_series_file: SxxExx detected" {
    is_tv_series_file "Show Name S01E05 Episode Title"
}

@test "is_tv_series_file: movie name not detected" {
    ! is_tv_series_file "Movie Title 2019 1080p BluRay"
}
