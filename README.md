# YTMusicAPI

[![Build Status](https://github.com/joshday/YTMusicAPI.jl/actions/workflows/CI.yml/badge.svg?branch=main)](https://github.com/joshday/YTMusicAPI.jl/actions/workflows/CI.yml?query=branch%3Amain)

A Julia package for retrieving data from YouTube Music. This is an unofficial API that works by emulating web client requests.

## Installation

```julia
using Pkg
Pkg.add(url="https://github.com/joshday/YTMusicAPI.jl")
```

## Quick Start

```julia
using YTMusicAPI

# Search for songs
results = search("Let it Be"; filter="songs", limit=5)
for r in results
    println(r.title, " by ", r.artist)
end

# Get song details
song = get_song(results[1].videoId)
println("Duration: ", song.lengthSeconds, " seconds")

# Get album details
albums = search("Abbey Road"; filter="albums", limit=1)
album = get_album(albums[1].browseId)
println(album.title, " (", album.year, ")")
for track in album.tracks
    println("  ", track.trackNumber, ". ", track.title)
end
```

## Authentication (OAuth)

Some features require authentication to access your personal library, playlists, and listening history. YTMusicAPI supports OAuth 2.0 device flow authentication.

### Setup

1. **Create OAuth credentials** in the [Google Cloud Console](https://console.cloud.google.com/):
   - Create a new project (or use an existing one)
   - Enable the YouTube Data API v3
   - If app is unpublished, add your email in Google Auth Platform/Audience/Test Users
   - Create OAuth 2.0 credentials (TV/Limited Input device)
   - Download the JSON file

2. **Place credentials file** at `~/.config/YTMusicAPI/oauth.json`

3. **Set environment variable** and load the package:

```bash
export YTMUSICAPI_OAUTH=~/.config/YTMusicAPI/oauth.json
```

```julia
using YTMusicAPI  # Automatically prompts for authentication on first load!
```

The package will detect that you have credentials but no token and automatically start the OAuth device flow, displaying a URL and code to enter in your browser.

4. **Use in future sessions** - everything is automatic:

```julia
using YTMusicAPI

# Global client `yt` is automatically authenticated
get_library_playlists()  # Works immediately!
```

### Environment Variable

`YTMUSICAPI_OAUTH` controls the path to your OAuth credentials file:
- If set and file exists with credentials but no token → auto-runs OAuth setup on package load
- If set and file has valid token → auto-authenticates
- Default fallback: `~/.config/YTMusicAPI/oauth.json`

### Manual Authentication

If you prefer not to use the environment variable:

```julia
using YTMusicAPI

# Run OAuth setup manually
yt = oauth_setup(oauth_path())

# Or with a specific file
yt = oauth_setup("/path/to/credentials.json")

# Or create credentials programmatically
credentials = OAuthCredentials(
    client_id = "your-client-id.apps.googleusercontent.com",
    client_secret = "your-client-secret"
)
yt = oauth_setup(credentials; save_to="~/.config/YTMusicAPI/oauth.json")
```

### Authenticated Functions

These functions require an authenticated client:

| Function | Description |
|----------|-------------|
| `get_library_playlists(; limit=25)` | Get your saved playlists |
| `get_library_songs(; limit=25)` | Get your liked songs |
| `get_library_albums(; limit=25)` | Get your saved albums |
| `get_library_artists(; limit=25)` | Get your followed artists |
| `get_liked_songs(; limit=25)` | Alias for `get_library_songs` |
| `get_history(; limit=25)` | Get your recently played songs |

### Playlist Management

| Function | Description |
|----------|-------------|
| `create_playlist(title; description="", privacy="PRIVATE")` | Create a new playlist |
| `get_playlist(playlist_id; limit=100)` | Get playlist contents with track details |
| `add_playlist_items(playlist_id, video_ids)` | Add songs to a playlist |
| `remove_playlist_items(playlist_id, set_video_ids)` | Remove songs from a playlist |
| `delete_playlist(playlist_id)` | Delete a playlist |

```julia
yt = YTMusic("oauth.json")

# Get your playlists
for playlist in get_library_playlists(yt)
    println(playlist.title, " (", playlist.trackCount, " tracks)")
end

# Get your listening history
for item in get_history(yt; limit=10)
    println(item.title, " by ", item.artist)
end

# Create a playlist and add songs
playlist_id = create_playlist(yt, "My New Playlist"; description="Created with YTMusicAPI")
results = search("Never Gonna Give You Up"; filter="songs", limit=1)
add_playlist_items(yt, playlist_id, results[1].videoId)

# Get playlist contents (includes setVideoId needed for removal)
playlist = get_playlist(yt, playlist_id)
println(playlist.title, " has ", length(playlist.tracks), " tracks")

# Remove a track (using setVideoId, not videoId)
if !isempty(playlist.tracks) && playlist.tracks[1].setVideoId !== nothing
    remove_playlist_items(yt, playlist_id, playlist.tracks[1].setVideoId)
end

# Delete the playlist
delete_playlist(yt, playlist_id)
```

## API Reference

### Client

```julia
YTMusic(; language="en", location="US")
YTMusic(oauth_file::String; language="en", location="US")
YTMusic(credentials::OAuthCredentials, token::OAuthToken; language="en", location="US")
```

Create a YouTube Music client. A global client `yt` is created automatically on package load, so you can use the convenience functions without creating your own client.

For authenticated access, provide an OAuth file path or credentials directly.

**Supported languages:** ar, cs, de, en, es, fr, hi, it, ja, ko, nl, pt, ru, tr, ur, zh_CN, zh_TW

**Supported locations:** Most country codes (US, GB, DE, FR, JP, etc.)

### Functions

All functions have two forms:
- With explicit client: `search(yt::YTMusic, query; ...)`
- Using global client: `search(query; ...)`

#### `search(query; filter=nothing, limit=20) -> Vector{SearchResult}`

Search YouTube Music.

**Filters:** `"songs"`, `"videos"`, `"albums"`, `"artists"`, `"playlists"`, `"podcasts"`, `"episodes"`

```julia
# Search everything
results = search("Beatles")

# Search only songs
songs = search("Yesterday"; filter="songs", limit=10)
```

#### `get_song(video_id) -> Song`

Get detailed information about a song.

```julia
song = get_song("dQw4w9WgXcQ")
println(song.title)        # Song title
println(song.artist)       # Artist name
println(song.lengthSeconds)# Duration in seconds
println(song.isPlayable)   # Whether the song can be played
```

#### `get_album(browse_id) -> Album`

Get album information including track listing.

```julia
# First find an album
results = search("Dark Side of the Moon"; filter="albums", limit=1)
album = get_album(results[1].browseId)

println(album.title)       # Album title
println(album.artist)      # Artist name
println(album.year)        # Release year
println(album.trackCount)  # Number of tracks

for track in album.tracks
    println(track.trackNumber, ". ", track.title, " (", track.duration, ")")
end
```

#### `get_artist(channel_id) -> Artist`

Get artist information and discography sections.

```julia
results = search("Pink Floyd"; filter="artists", limit=1)
artist = get_artist(results[1].browseId)

println(artist.name)
println(artist.subscribers)

# Available sections vary by artist (albums, singles, songs, videos, etc.)
for (section_name, items) in artist.sections
    println("\n", uppercase(section_name), ":")
    for item in items[1:min(3, length(items))]
        println("  - ", item.title)
    end
end
```

#### `get_watch_playlist(video_id; limit=25) -> WatchPlaylist`

Get the "Up Next" queue for a song, including related tracks.

```julia
playlist = get_watch_playlist("dQw4w9WgXcQ")

for track in playlist.tracks
    println(track.title, " by ", track.artist)
end

# Get lyrics browse ID if available
println("Lyrics ID: ", playlist.lyricsId)
```

#### `get_lyrics(browse_id) -> Lyrics`

Get lyrics for a song. The lyrics browse ID can be obtained from `get_watch_playlist`.

```julia
playlist = get_watch_playlist("dQw4w9WgXcQ")
if playlist.lyricsId !== nothing
    lyrics = get_lyrics(playlist.lyricsId)
    println(lyrics.lyrics)
    println("Source: ", lyrics.source)
end
```

### Constructors from SearchResult

You can also construct `Song`, `Album`, `Artist`, and `WatchPlaylist` directly from a `SearchResult`. This provides a convenient shorthand that fetches the full details automatically.

```julia
# Instead of:
results = search("Yesterday"; filter="songs", limit=1)
song = get_song(results[1].videoId)

# You can write:
results = search("Yesterday"; filter="songs", limit=1)
song = Song(results[1])
```

**Available constructors:**

| Constructor | Requirement |
|-------------|-------------|
| `Song(result::SearchResult)` | Result must have a `videoId` |
| `Album(result::SearchResult)` | Result must have a `browseId` starting with "MPREb" |
| `Artist(result::SearchResult)` | Result must have a `browseId` starting with "UC" or an `artistId` |
| `WatchPlaylist(result::SearchResult; limit=25)` | Result must have a `videoId` |

**Artist can also be constructed from other types:**

```julia
# Get the artist of a song
song = get_song("dQw4w9WgXcQ")
artist = Artist(song)

# Get the artist of an album
album = get_album("MPREb_...")
artist = Artist(album)
```

| Constructor | Requirement |
|-------------|-------------|
| `Artist(song::Song)` | Song must have a `channelId` |
| `Artist(album::Album)` | Album must have an `artistId` |
| `Artist(track::Track)` | Track must have an `artistId` |
| `Artist(track::PlaylistTrack)` | Track must have an `artistId` |
| `Artist(item::ArtistItem)` | Item must have a `browseId` starting with "UC" |

These constructors will throw an error if the required ID is not present.

## Acknowledgments

This package is inspired by the Python [ytmusicapi](https://github.com/sigma67/ytmusicapi) library.

## Disclaimer

This is an unofficial API and is not affiliated with or endorsed by YouTube or Google. Use responsibly and in accordance with YouTube's Terms of Service.
