#=
Similar Bands Playlist Generator

This script uses an LLM (Claude or ChatGPT) to find bands similar to a given artist,
then creates a YouTube Music playlist with songs from those bands.

## Requirements

- YTMusicAPI.jl with OAuth authentication configured
- HTTP.jl and JSON3.jl (included with YTMusicAPI)
- Either ANTHROPIC_API_KEY or OPENAI_API_KEY environment variable set

## Usage

```julia
include("examples/similar_bands_playlist.jl")

# Using Claude (default if ANTHROPIC_API_KEY is set)
create_similar_bands_playlist("Radiohead"; num_bands=5, songs_per_band=2)

# Using OpenAI
create_similar_bands_playlist("Radiohead"; provider=:openai, num_bands=5, songs_per_band=2)
```
=#

using YTMusicAPI
using HTTP
using JSON3

#-----------------------------------------------------------------------------# LLM API Calls

"""
    get_similar_bands_claude(artist::String; num_bands::Int=5) -> Vector{String}

Use Claude to get a list of bands similar to the given artist.
Requires ANTHROPIC_API_KEY environment variable.
"""
function get_similar_bands_claude(artist::String; num_bands::Int=5)
    api_key = get(ENV, "ANTHROPIC_API_KEY", "")
    isempty(api_key) && error("ANTHROPIC_API_KEY environment variable not set")

    prompt = """List exactly $num_bands bands/artists that are similar to "$artist".

Return ONLY a JSON array of band names, nothing else. Example format:
["Band 1", "Band 2", "Band 3"]

Focus on artists with a similar sound, genre, or style. Do not include "$artist" itself."""

    body = Dict(
        "model" => "claude-sonnet-4-20250514",
        "max_tokens" => 256,
        "messages" => [
            Dict("role" => "user", "content" => prompt)
        ]
    )

    response = HTTP.post(
        "https://api.anthropic.com/v1/messages",
        headers = Dict(
            "Content-Type" => "application/json",
            "x-api-key" => api_key,
            "anthropic-version" => "2023-06-01"
        ),
        body = JSON3.write(body),
        status_exception = false
    )

    if response.status != 200
        error("Claude API request failed ($(response.status)): $(String(response.body))")
    end

    result = JSON3.read(String(response.body))
    text = result[:content][1][:text]

    # Parse JSON array from response
    return JSON3.read(text, Vector{String})
end

"""
    get_similar_bands_openai(artist::String; num_bands::Int=5) -> Vector{String}

Use ChatGPT to get a list of bands similar to the given artist.
Requires OPENAI_API_KEY environment variable.
"""
function get_similar_bands_openai(artist::String; num_bands::Int=5)
    api_key = get(ENV, "OPENAI_API_KEY", "")
    isempty(api_key) && error("OPENAI_API_KEY environment variable not set")

    prompt = """List exactly $num_bands bands/artists that are similar to "$artist".

Return ONLY a JSON array of band names, nothing else. Example format:
["Band 1", "Band 2", "Band 3"]

Focus on artists with a similar sound, genre, or style. Do not include "$artist" itself."""

    body = Dict(
        "model" => "gpt-4o-mini",
        "messages" => [
            Dict("role" => "user", "content" => prompt)
        ],
        "max_tokens" => 256
    )

    response = HTTP.post(
        "https://api.openai.com/v1/chat/completions",
        headers = Dict(
            "Content-Type" => "application/json",
            "Authorization" => "Bearer $api_key"
        ),
        body = JSON3.write(body),
        status_exception = false
    )

    if response.status != 200
        error("OpenAI API request failed ($(response.status)): $(String(response.body))")
    end

    result = JSON3.read(String(response.body))
    text = result[:choices][1][:message][:content]

    # Parse JSON array from response (handle markdown code blocks)
    text = replace(text, r"```json\s*" => "")
    text = replace(text, r"```\s*" => "")
    text = strip(text)

    return JSON3.read(text, Vector{String})
end

"""
    get_similar_bands(artist::String; provider::Symbol=:auto, num_bands::Int=5) -> Vector{String}

Get similar bands using the specified LLM provider.

# Arguments
- `artist`: The artist to find similar bands for
- `provider`: `:claude`, `:openai`, or `:auto` (uses whichever API key is available)
- `num_bands`: Number of similar bands to return
"""
function get_similar_bands(artist::String; provider::Symbol=:auto, num_bands::Int=5)
    if provider == :auto
        if haskey(ENV, "ANTHROPIC_API_KEY")
            provider = :claude
        elseif haskey(ENV, "OPENAI_API_KEY")
            provider = :openai
        else
            error("No LLM API key found. Set ANTHROPIC_API_KEY or OPENAI_API_KEY.")
        end
    end

    if provider == :claude
        return get_similar_bands_claude(artist; num_bands)
    elseif provider == :openai
        return get_similar_bands_openai(artist; num_bands)
    else
        error("Unknown provider: $provider. Use :claude or :openai.")
    end
end

#-----------------------------------------------------------------------------# Playlist Creation

"""
    create_similar_bands_playlist(artist::String; provider::Symbol=:auto, num_bands::Int=5, songs_per_band::Int=2, playlist_name::String="") -> String

Create a YouTube Music playlist with songs from bands similar to the given artist.

# Arguments
- `artist`: The artist to find similar bands for
- `provider`: LLM provider (`:claude`, `:openai`, or `:auto`)
- `num_bands`: Number of similar bands to find (default: 5)
- `songs_per_band`: Number of songs to add per band (default: 2)
- `playlist_name`: Custom playlist name (default: "Similar to [artist]")

# Returns
The playlist ID of the created playlist.

# Example
```julia
playlist_id = create_similar_bands_playlist("Radiohead"; num_bands=5, songs_per_band=2)
```
"""
function create_similar_bands_playlist(
    artist::String;
    provider::Symbol = :auto,
    num_bands::Int = 5,
    songs_per_band::Int = 2,
    playlist_name::String = ""
)
    # Ensure we're authenticated
    if !is_authenticated(yt[])
        error("YouTube Music client is not authenticated. Set up OAuth first.")
    end

    println("Finding bands similar to \"$artist\"...")
    similar_bands = get_similar_bands(artist; provider, num_bands)
    println("Found $(length(similar_bands)) similar bands: $(join(similar_bands, ", "))")

    # Collect songs from each band
    video_ids = String[]
    songs_info = Tuple{String, String, String}[]  # (title, artist, videoId)

    for band in similar_bands
        println("\nSearching for songs by \"$band\"...")
        try
            results = search("$band"; filter="songs", limit=songs_per_band * 2)

            added = 0
            for r in results
                added >= songs_per_band && break
                r.videoId === nothing && continue

                # Verify this song is actually by the artist we searched for
                if r.artist !== nothing && occursin(lowercase(band), lowercase(r.artist))
                    push!(video_ids, r.videoId)
                    push!(songs_info, (r.title, r.artist, r.videoId))
                    added += 1
                    println("  + $(r.title) by $(r.artist)")
                end
            end

            if added == 0
                # Fallback: just take the first results
                for r in results[1:min(songs_per_band, length(results))]
                    r.videoId === nothing && continue
                    push!(video_ids, r.videoId)
                    push!(songs_info, (something(r.title, "Unknown"), something(r.artist, band), r.videoId))
                    println("  + $(something(r.title, "Unknown")) by $(something(r.artist, band))")
                end
            end
        catch e
            println("  Error searching for $band: $e")
        end
    end

    if isempty(video_ids)
        error("Could not find any songs from similar bands")
    end

    # Create the playlist
    name = isempty(playlist_name) ? "Similar to $artist" : playlist_name
    description = "Artists similar to $artist: $(join(similar_bands, ", ")). Generated with YTMusicAPI.jl"

    println("\nCreating playlist \"$name\" with $(length(video_ids)) songs...")
    playlist_id = create_playlist(name; description, privacy="PRIVATE")
    println("Created playlist: $playlist_id")

    # Add songs to playlist
    println("Adding songs to playlist...")
    add_playlist_items(playlist_id, video_ids)

    println("\nPlaylist created successfully!")
    println("Songs added:")
    for (i, (title, artist, _)) in enumerate(songs_info)
        println("  $i. $title by $artist")
    end

    return playlist_id
end

# Print usage info when script is included
println("""
Similar Bands Playlist Generator loaded!

Usage:
  create_similar_bands_playlist("Artist Name"; num_bands=5, songs_per_band=2)

Options:
  - provider: :claude, :openai, or :auto (default)
  - num_bands: number of similar artists to find (default: 5)
  - songs_per_band: songs to add per artist (default: 2)
  - playlist_name: custom name for the playlist

Example:
  create_similar_bands_playlist("Pink Floyd"; num_bands=5, songs_per_band=3)
""")
