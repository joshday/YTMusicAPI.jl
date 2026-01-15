module YTMusicAPI

using HTTP
using JSON3
using Dates

export YTMusic, yt, search, get_artist, get_album, get_song, get_lyrics, get_watch_playlist
export SearchResult, Song, Video, Album, Artist, Track, Lyrics, WatchPlaylist, PlaylistTrack, ArtistItem
# OAuth exports
export oauth_setup, oauth_refresh!, is_authenticated, oauth_path
export OAuthCredentials, OAuthToken
# Library exports (authenticated)
export get_library_playlists, get_library_songs, get_library_albums, get_library_artists
export get_liked_songs, get_history, Playlist, LibraryItem
# Playlist management exports (authenticated)
export create_playlist, add_playlist_items, remove_playlist_items, delete_playlist, get_playlist

#-----------------------------------------------------------------------------# Types
const Maybe{T} = Union{T, Nothing}

"""Search result from YouTube Music."""
Base.@kwdef struct SearchResult
    title::Maybe{String} = nothing
    videoId::Maybe{String} = nothing
    browseId::Maybe{String} = nothing
    artist::Maybe{String} = nothing
    artistId::Maybe{String} = nothing
    album::Maybe{String} = nothing
    albumId::Maybe{String} = nothing
    duration::Maybe{String} = nothing
    thumbnail::Maybe{String} = nothing
end

"""Detailed song information from get_song."""
Base.@kwdef struct Song
    videoId::Maybe{String} = nothing
    title::Maybe{String} = nothing
    artist::Maybe{String} = nothing
    channelId::Maybe{String} = nothing
    lengthSeconds::Maybe{String} = nothing
    viewCount::Maybe{String} = nothing
    thumbnail::Maybe{String} = nothing
    playabilityStatus::Maybe{String} = nothing
    isPlayable::Bool = false
    category::Maybe{String} = nothing
    publishDate::Maybe{String} = nothing
    uploadDate::Maybe{String} = nothing
end

"""Track in an album."""
Base.@kwdef struct Track
    trackNumber::Int = 0
    title::Maybe{String} = nothing
    videoId::Maybe{String} = nothing
    artist::Maybe{String} = nothing
    artistId::Maybe{String} = nothing
    duration::Maybe{String} = nothing
    thumbnail::Maybe{String} = nothing
    isAvailable::Bool = false
end

"""Album information."""
Base.@kwdef struct Album
    browseId::Maybe{String} = nothing
    title::Maybe{String} = nothing
    artist::Maybe{String} = nothing
    artistId::Maybe{String} = nothing
    year::Maybe{String} = nothing
    type::Maybe{String} = nothing
    trackCount::Maybe{Int} = nothing
    duration::Maybe{String} = nothing
    thumbnail::Maybe{String} = nothing
    description::Maybe{String} = nothing
    audioPlaylistId::Maybe{String} = nothing
    tracks::Vector{Track} = Track[]
end

"""Item in an artist's section (song, album, video, etc.)."""
Base.@kwdef struct ArtistItem
    title::Maybe{String} = nothing
    browseId::Maybe{String} = nothing
    videoId::Maybe{String} = nothing
    thumbnail::Maybe{String} = nothing
    subtitle::Maybe{String} = nothing
end

"""Artist information."""
Base.@kwdef struct Artist
    name::Maybe{String} = nothing
    channelId::Maybe{String} = nothing
    description::Maybe{String} = nothing
    thumbnail::Maybe{String} = nothing
    subscribers::Maybe{String} = nothing
    sections::Dict{String, Vector{ArtistItem}} = Dict{String, Vector{ArtistItem}}()
end

"""Lyrics for a song."""
Base.@kwdef struct Lyrics
    browseId::Maybe{String} = nothing
    lyrics::Maybe{String} = nothing
    source::Maybe{String} = nothing
end

"""Track in a watch playlist."""
Base.@kwdef struct PlaylistTrack
    videoId::Maybe{String} = nothing
    title::Maybe{String} = nothing
    artist::Maybe{String} = nothing
    artistId::Maybe{String} = nothing
    duration::Maybe{String} = nothing
    thumbnail::Maybe{String} = nothing
end

"""Watch playlist (queue) for a video."""
Base.@kwdef struct WatchPlaylist
    playlistId::Maybe{String} = nothing
    tracks::Vector{PlaylistTrack} = PlaylistTrack[]
    lyricsId::Maybe{String} = nothing
end

"""User playlist from library."""
Base.@kwdef struct Playlist
    playlistId::Maybe{String} = nothing
    title::Maybe{String} = nothing
    description::Maybe{String} = nothing
    thumbnail::Maybe{String} = nothing
    trackCount::Maybe{Int} = nothing
    author::Maybe{String} = nothing
end

"""Item from user's library (song, album, artist, etc.)."""
Base.@kwdef struct LibraryItem
    title::Maybe{String} = nothing
    videoId::Maybe{String} = nothing
    browseId::Maybe{String} = nothing
    playlistId::Maybe{String} = nothing
    artist::Maybe{String} = nothing
    artistId::Maybe{String} = nothing
    album::Maybe{String} = nothing
    albumId::Maybe{String} = nothing
    duration::Maybe{String} = nothing
    thumbnail::Maybe{String} = nothing
    likeStatus::Maybe{String} = nothing
end

#-----------------------------------------------------------------------------# OAuth Types
"""OAuth credentials (client_id and client_secret from Google Cloud Console)."""
Base.@kwdef struct OAuthCredentials
    client_id::String
    client_secret::String
end

"""OAuth token with access and refresh tokens."""
Base.@kwdef mutable struct OAuthToken
    access_token::String = ""
    refresh_token::String = ""
    token_type::String = "Bearer"
    expires_at::DateTime = DateTime(1970)
    scope::String = ""
end

function Base.show(io::IO, token::OAuthToken)
    expired = token.expires_at < now()
    print(io, "OAuthToken(expires_at=$(token.expires_at), expired=$expired)")
end

"""Check if token is expired (with 60 second buffer)."""
is_expired(token::OAuthToken) = token.expires_at < now() + Second(60)

#-----------------------------------------------------------------------------# Constants
const YTM_DOMAIN = "https://music.youtube.com"
const YTM_BASE_API = YTM_DOMAIN * "/youtubei/v1/"
const YTM_PARAMS = "?alt=json"
const USER_AGENT = "Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:88.0) Gecko/20100101 Firefox/88.0"

# YouTube Data API (official API, works with OAuth)
const YT_DATA_API = "https://www.googleapis.com/youtube/v3/"

# OAuth constants
const OAUTH_CODE_URL = "https://www.youtube.com/o/oauth2/device/code"
const OAUTH_TOKEN_URL = "https://oauth2.googleapis.com/token"
const OAUTH_SCOPE = "https://www.googleapis.com/auth/youtube"
const OAUTH_USER_AGENT = USER_AGENT * " Cobalt/Version"
const OAUTH_GRANT_TYPE_DEVICE = "http://oauth.net/grant_type/device/1.0"
const OAUTH_DEFAULT_PATH = joinpath(homedir(), ".config", "YTMusicAPI", "oauth.json")

"""
    oauth_path() -> Union{String, Nothing}

Get the path to OAuth credentials file.

Checks in order:
1. `YTMUSICAPI_OAUTH` environment variable
2. Default path: `~/.config/YTMusicAPI/oauth.json`

Returns `nothing` if no credentials file exists.

# Example
```julia
# Set via environment variable
ENV["YTMUSICAPI_OAUTH"] = "/path/to/my/oauth.json"

# Or use default location
# ~/.config/YTMusicAPI/oauth.json

path = oauth_path()
if path !== nothing
    yt = YTMusic(path)
end
```
"""
function oauth_path()
    # Check environment variable first
    env_path = get(ENV, "YTMUSICAPI_OAUTH", nothing)
    if env_path !== nothing && isfile(env_path)
        return env_path
    end
    # Fall back to default path
    if isfile(OAUTH_DEFAULT_PATH)
        return OAUTH_DEFAULT_PATH
    end
    return nothing
end

# Library browse IDs for authenticated requests
const LIBRARY_BROWSE_IDS = Dict(
    "playlists" => "FEmusic_liked_playlists",
    "songs" => "FEmusic_liked_videos",
    "albums" => "FEmusic_liked_albums",
    "artists" => "FEmusic_library_corpus_track_artists",
    "subscriptions" => "FEmusic_library_corpus_artists",
    "history" => "FEmusic_history",
)

const SUPPORTED_LANGUAGES = [
    "ar", "cs", "de", "en", "es", "fr", "hi", "it", "ja", "ko",
    "nl", "pt", "ru", "tr", "ur", "zh_CN", "zh_TW"
]

const SUPPORTED_LOCATIONS = [
    "AE", "AR", "AT", "AU", "AZ", "BA", "BD", "BE", "BG", "BH", "BO", "BR", "BY",
    "CA", "CH", "CL", "CO", "CR", "CY", "CZ", "DE", "DK", "DO", "DZ", "EC", "EE",
    "EG", "ES", "FI", "FR", "GB", "GE", "GH", "GR", "GT", "HK", "HN", "HR", "HU",
    "ID", "IE", "IL", "IN", "IQ", "IS", "IT", "JM", "JO", "JP", "KE", "KH", "KR",
    "KW", "KZ", "LA", "LB", "LI", "LK", "LT", "LU", "LV", "LY", "MA", "ME", "MK",
    "MT", "MX", "MY", "NG", "NI", "NL", "NO", "NP", "NZ", "OM", "PA", "PE", "PH",
    "PK", "PL", "PR", "PT", "PY", "QA", "RO", "RS", "RU", "SA", "SE", "SG", "SI",
    "SK", "SN", "SV", "TH", "TN", "TR", "TW", "TZ", "UA", "UG", "US", "UY", "VE",
    "VN", "YE", "ZA", "ZW"
]

const SEARCH_FILTERS = Dict(
    "songs" => "EgWKAQIIAWoMEAMQBBAJEA4QChAF",
    "videos" => "EgWKAQIQAWoMEAMQBBAJEA4QChAF",
    "albums" => "EgWKAQIYAWoMEAMQBBAJEA4QChAF",
    "artists" => "EgWKAQIgAWoMEAMQBBAJEA4QChAF",
    "playlists" => "EgWKAQIoAWoMEAMQBBAJEA4QChAF",
    "community_playlists" => "EgWKAQIoAWoMEAMQBBAJEA4QChAF",
    "featured_playlists" => "EgWKAQIoBWoMEAMQBBAJEA4QChAF",
    "podcasts" => "EgWKAQJQAWoMEAMQBBAJEA4QChAF",
    "episodes" => "EgWKAQJYAWoMEAMQBBAJEA4QChAF"
)

#-----------------------------------------------------------------------------# YTMusic Client
"""
    YTMusic(; language="en", location="US")
    YTMusic(oauth_file::String; language="en", location="US")
    YTMusic(credentials::OAuthCredentials, token::OAuthToken; language="en", location="US")

Create a YouTube Music client for making API requests.

# Arguments
- `language::String`: Language code for results (default: "en")
- `location::String`: Country code for regional content (default: "US")
- `oauth_file::String`: Path to JSON file containing OAuth credentials and token
- `credentials::OAuthCredentials`: OAuth client credentials
- `token::OAuthToken`: OAuth access/refresh token

# Examples
```julia
# Unauthenticated client
yt = YTMusic()

# Authenticated client from file
yt = YTMusic("oauth.json")

# Authenticated client from credentials
yt = YTMusic(credentials, token)
```
"""
mutable struct YTMusic
    language::String
    location::String
    headers::Dict{String,String}
    context::Dict{String,Any}
    visitor_id::String
    oauth_credentials::Maybe{OAuthCredentials}
    oauth_token::Maybe{OAuthToken}

    function YTMusic(; language::String="en", location::String="US",
                     oauth_credentials::Maybe{OAuthCredentials}=nothing,
                     oauth_token::Maybe{OAuthToken}=nothing)
        language in SUPPORTED_LANGUAGES || error("Unsupported language: $language. Supported: $SUPPORTED_LANGUAGES")
        location in SUPPORTED_LOCATIONS || error("Unsupported location: $location. Supported: $SUPPORTED_LOCATIONS")

        headers = Dict{String,String}(
            "User-Agent" => USER_AGENT,
            "Accept" => "*/*",
            "Accept-Language" => "$language,en-US;q=0.9,en;q=0.8",
            "Content-Type" => "application/json",
            "Origin" => YTM_DOMAIN,
            "Referer" => YTM_DOMAIN * "/",
        )

        # Client version uses current date like Python library
        client_version = "1." * Dates.format(now(Dates.UTC), "yyyymmdd") * ".01.00"

        context = Dict{String,Any}(
            "client" => Dict{String,Any}(
                "clientName" => "WEB_REMIX",
                "clientVersion" => client_version,
                "hl" => language,
                "gl" => location,
            ),
            "user" => Dict{String,Any}()
        )

        yt = new(language, location, headers, context, "", oauth_credentials, oauth_token)
        yt.visitor_id = get_visitor_id(yt)
        if !isempty(yt.visitor_id)
            yt.headers["X-Goog-Visitor-Id"] = yt.visitor_id
        end
        return yt
    end
end

# Constructor from OAuth file
function YTMusic(oauth_file::String; language::String="en", location::String="US")
    isfile(oauth_file) || error("OAuth file not found: $oauth_file")
    data = JSON3.read(read(oauth_file, String), Dict)

    # Handle Google's download format: { "installed": { "client_id": ..., "client_secret": ... } }
    if haskey(data, "installed") || haskey(data, :installed)
        installed = get(data, "installed", get(data, :installed, nothing))
        client_id = get(installed, "client_id", get(installed, :client_id, nothing))
        client_secret = get(installed, "client_secret", get(installed, :client_secret, nothing))

        credentials = OAuthCredentials(client_id=string(client_id), client_secret=string(client_secret))

        # No token yet - return client with just credentials (user needs to run oauth_setup)
        return YTMusic(; language, location, oauth_credentials=credentials, oauth_token=nothing)
    end

    # Our saved format: { "client_id": ..., "client_secret": ..., "access_token": ..., ... }
    credentials = OAuthCredentials(
        client_id = string(data["client_id"]),
        client_secret = string(data["client_secret"])
    )

    token = OAuthToken(
        access_token = string(get(data, "access_token", "")),
        refresh_token = string(get(data, "refresh_token", "")),
        token_type = string(get(data, "token_type", "Bearer")),
        expires_at = DateTime(string(get(data, "expires_at", "1970-01-01T00:00:00"))),
        scope = string(get(data, "scope", OAUTH_SCOPE))
    )

    yt = YTMusic(; language, location, oauth_credentials=credentials, oauth_token=token)

    # Refresh token if expired and we have a refresh token
    if !isempty(token.refresh_token) && is_expired(token)
        oauth_refresh!(yt)
    end

    return yt
end

# Constructor from credentials and token
function YTMusic(credentials::OAuthCredentials, token::OAuthToken; language::String="en", location::String="US")
    YTMusic(; language, location, oauth_credentials=credentials, oauth_token=token)
end

const yt = Ref{YTMusic}()

function __init__()
    # Auto-load OAuth credentials if available
    path = oauth_path()
    if path !== nothing
        try
            client = YTMusic(path)
            # If credentials loaded but no token, and YTMUSICAPI_OAUTH is set, run oauth_setup
            if client.oauth_credentials !== nothing && !is_authenticated(client) && haskey(ENV, "YTMUSICAPI_OAUTH")
                println("OAuth credentials found but no token. Starting authentication...")
                client = oauth_setup(client; save_to=path)
            end
            yt[] = client
        catch e
            @warn "Failed to load OAuth credentials from $path: $e"
            yt[] = YTMusic()
        end
    else
        yt[] = YTMusic()
    end
end

function Base.show(io::IO, yt::YTMusic)
    auth_str = is_authenticated(yt) ? ", authenticated=true" : ""
    print(io, "YTMusic(language=$(repr(yt.language)), location=$(repr(yt.location))$auth_str)")
end

"""Check if the client is authenticated."""
is_authenticated(yt::YTMusic) = yt.oauth_token !== nothing && !isempty(yt.oauth_token.access_token)

#-----------------------------------------------------------------------------# Internal: get_visitor_id
function get_visitor_id(yt::YTMusic)
    try
        response = HTTP.get(YTM_DOMAIN; headers=yt.headers, status_exception=false)
        body = String(response.body)
        m = match(r"ytcfg\.set\s*\(\s*\{[^}]*\"VISITOR_DATA\"\s*:\s*\"([^\"]+)\"", body)
        return m !== nothing ? m.captures[1] : ""
    catch
        return ""
    end
end

#-----------------------------------------------------------------------------# OAuth Functions
"""
    oauth_setup(credentials::OAuthCredentials; save_to::String="") -> (YTMusic, String)

Perform OAuth device flow authentication. Returns authenticated YTMusic client.

# Process
1. Displays a URL and code for user to authorize
2. Waits for user to complete authorization
3. Exchanges code for tokens
4. Optionally saves credentials to file

# Arguments
- `credentials::OAuthCredentials`: Client credentials from Google Cloud Console
- `save_to::String`: Optional path to save OAuth credentials for future use

# Example
```julia
credentials = OAuthCredentials(client_id="...", client_secret="...")
yt = oauth_setup(credentials; save_to="oauth.json")
```
"""
function oauth_setup(credentials::OAuthCredentials; save_to::String="", language::String="en", location::String="US")
    # Step 1: Request device code
    println("Requesting device code...")
    code_response = HTTP.post(OAUTH_CODE_URL;
        headers = Dict(
            "User-Agent" => OAUTH_USER_AGENT,
            "Content-Type" => "application/x-www-form-urlencoded"
        ),
        body = HTTP.URIs.escapeuri(Dict(
            "client_id" => credentials.client_id,
            "scope" => OAUTH_SCOPE
        )),
        status_exception = false
    )

    if code_response.status != 200
        error("Failed to get device code: $(String(code_response.body))")
    end

    code_data = JSON3.read(String(code_response.body), Dict)
    device_code = code_data["device_code"]
    user_code = code_data["user_code"]
    verification_url = get(code_data, "verification_url", "https://www.google.com/device")
    interval = get(code_data, "interval", 5)
    expires_in = get(code_data, "expires_in", 1800)

    # Step 2: Display instructions to user
    println()
    println("=" ^ 60)
    println("  Go to: $verification_url")
    println("  Enter code: $user_code")
    println("=" ^ 60)
    println()
    println("Waiting for authorization (expires in $(expires_in ÷ 60) minutes)...")

    # Step 3: Poll for token
    token = nothing
    start_time = time()
    while time() - start_time < expires_in
        sleep(interval)

        token_response = HTTP.post(OAUTH_TOKEN_URL;
            headers = Dict(
                "User-Agent" => OAUTH_USER_AGENT,
                "Content-Type" => "application/x-www-form-urlencoded"
            ),
            body = HTTP.URIs.escapeuri(Dict(
                "client_id" => credentials.client_id,
                "client_secret" => credentials.client_secret,
                "code" => device_code,
                "grant_type" => OAUTH_GRANT_TYPE_DEVICE
            )),
            status_exception = false
        )

        token_data = JSON3.read(String(token_response.body), Dict)

        if token_response.status == 200
            # Success!
            expires_in_secs = get(token_data, "expires_in", 3600)
            token = OAuthToken(
                access_token = token_data["access_token"],
                refresh_token = get(token_data, "refresh_token", ""),
                token_type = get(token_data, "token_type", "Bearer"),
                expires_at = now() + Second(expires_in_secs),
                scope = get(token_data, "scope", OAUTH_SCOPE)
            )
            println("Authorization successful!")
            break
        elseif haskey(token_data, "error")
            error_code = token_data["error"]
            if error_code == "authorization_pending"
                print(".")  # Still waiting
            elseif error_code == "slow_down"
                interval += 1
            elseif error_code == "access_denied"
                error("User denied access")
            elseif error_code == "expired_token"
                error("Authorization expired. Please try again.")
            else
                error("OAuth error: $error_code")
            end
        end
    end

    if token === nothing
        error("Authorization timed out")
    end

    # Create authenticated client
    yt = YTMusic(credentials, token; language, location)

    # Save to file if requested
    if !isempty(save_to)
        oauth_save(yt, save_to)
        println("Credentials saved to: $save_to")
    end

    return yt
end

"""
    oauth_setup(yt::YTMusic; save_to::String="") -> YTMusic

Run OAuth device flow on a client that has credentials loaded but no token.
Useful after loading credentials from Google's download format.

# Example
```julia
yt = YTMusic("~/.config/YTMusicAPI/oauth.json")  # Loads credentials only
yt = oauth_setup(yt; save_to="~/.config/YTMusicAPI/oauth.json")  # Gets token and saves
```
"""
function oauth_setup(yt::YTMusic; save_to::String="")
    yt.oauth_credentials === nothing && error("No OAuth credentials configured. Load credentials first.")
    return oauth_setup(yt.oauth_credentials; save_to, language=yt.language, location=yt.location)
end

"""
    oauth_setup(oauth_file::String; save_to::String="") -> YTMusic

Run OAuth device flow using credentials from a file.

# Example
```julia
yt = oauth_setup("~/.config/YTMusicAPI/oauth.json"; save_to="~/.config/YTMusicAPI/oauth.json")
```
"""
function oauth_setup(oauth_file::String; save_to::String="")
    yt = YTMusic(oauth_file)
    yt.oauth_credentials === nothing && error("No OAuth credentials found in $oauth_file")

    # If we already have a valid token, just return the client
    if is_authenticated(yt)
        return yt
    end

    # Otherwise run the device flow
    return oauth_setup(yt.oauth_credentials; save_to=isempty(save_to) ? oauth_file : save_to, language=yt.language, location=yt.location)
end

"""
    oauth_refresh!(yt::YTMusic)

Refresh the OAuth access token. Modifies the client in-place.
"""
function oauth_refresh!(yt::YTMusic)
    yt.oauth_credentials === nothing && error("No OAuth credentials configured")
    yt.oauth_token === nothing && error("No OAuth token configured")
    isempty(yt.oauth_token.refresh_token) && error("No refresh token available")

    response = HTTP.post(OAUTH_TOKEN_URL;
        headers = Dict(
            "User-Agent" => OAUTH_USER_AGENT,
            "Content-Type" => "application/x-www-form-urlencoded"
        ),
        body = HTTP.URIs.escapeuri(Dict(
            "client_id" => yt.oauth_credentials.client_id,
            "client_secret" => yt.oauth_credentials.client_secret,
            "refresh_token" => yt.oauth_token.refresh_token,
            "grant_type" => "refresh_token"
        )),
        status_exception = false
    )

    if response.status != 200
        error("Failed to refresh token: $(String(response.body))")
    end

    data = JSON3.read(String(response.body), Dict)
    expires_in = get(data, "expires_in", 3600)

    yt.oauth_token.access_token = data["access_token"]
    yt.oauth_token.expires_at = now() + Second(expires_in)
    if haskey(data, "refresh_token")
        yt.oauth_token.refresh_token = data["refresh_token"]
    end

    return yt
end

"""
    oauth_save(yt::YTMusic, filepath::String)

Save OAuth credentials and token to a JSON file.
"""
function oauth_save(yt::YTMusic, filepath::String)
    yt.oauth_credentials === nothing && error("No OAuth credentials to save")
    yt.oauth_token === nothing && error("No OAuth token to save")

    data = Dict(
        "client_id" => yt.oauth_credentials.client_id,
        "client_secret" => yt.oauth_credentials.client_secret,
        "access_token" => yt.oauth_token.access_token,
        "refresh_token" => yt.oauth_token.refresh_token,
        "token_type" => yt.oauth_token.token_type,
        "expires_at" => string(yt.oauth_token.expires_at),
        "scope" => yt.oauth_token.scope
    )

    open(filepath, "w") do io
        JSON3.pretty(io, data)
    end
end

"""Ensure token is valid, refreshing if needed."""
function ensure_token!(yt::YTMusic)
    if is_authenticated(yt) && is_expired(yt.oauth_token)
        oauth_refresh!(yt)
    end
end

"""Check if authentication is required and throw error if not authenticated."""
function require_auth(yt::YTMusic)
    is_authenticated(yt) || error("This function requires authentication. Use oauth_setup() first.")
    ensure_token!(yt)
end

#-----------------------------------------------------------------------------# Internal: send_request
function send_request(yt::YTMusic, endpoint::String, body::Dict; require_authentication::Bool=false)
    if require_authentication
        require_auth(yt)
    end

    # Refresh token if needed
    if is_authenticated(yt)
        ensure_token!(yt)
    end

    url = YTM_BASE_API * endpoint * YTM_PARAMS
    body["context"] = yt.context

    # Build headers, adding OAuth only when authentication is required
    headers = copy(yt.headers)
    if require_authentication && is_authenticated(yt)
        headers["Authorization"] = "Bearer $(yt.oauth_token.access_token)"
        headers["X-Goog-Request-Time"] = string(round(Int, time()))
    end

    response = HTTP.post(url;
        headers = headers,
        body = JSON3.write(body),
        status_exception = false
    )

    if response.status != 200
        error("API request failed with status $(response.status): $(String(response.body))")
    end

    return JSON3.read(String(response.body), Dict)
end

#-----------------------------------------------------------------------------# YouTube Data API helpers
"""Send a GET request to the YouTube Data API (official API)."""
function send_data_api_request(yt::YTMusic, endpoint::String; params::Dict{String,String}=Dict{String,String}())
    require_auth(yt)
    ensure_token!(yt)

    # Build query string
    query_parts = [k * "=" * HTTP.URIs.escapeuri(v) for (k, v) in params]
    query_string = isempty(query_parts) ? "" : "&" * join(query_parts, "&")

    url = YT_DATA_API * endpoint * "?alt=json" * query_string

    headers = Dict{String,String}(
        "Authorization" => "Bearer $(yt.oauth_token.access_token)",
        "Accept" => "application/json"
    )

    response = HTTP.get(url; headers=headers, status_exception=false)

    if response.status != 200
        error("YouTube Data API request failed with status $(response.status): $(String(response.body))")
    end

    return JSON3.read(String(response.body), Dict)
end

#-----------------------------------------------------------------------------# Navigation helpers
"""Navigate through nested Dict/Array structures using a path of keys/indices."""
function nav(root, path...; default=nothing)
    current = root
    for key in path
        if current === nothing
            return default
        elseif key isa Integer
            if current isa AbstractVector && 1 <= key <= length(current)
                current = current[key]
            else
                return default
            end
        elseif current isa AbstractDict && haskey(current, key)
            current = current[key]
        elseif current isa AbstractDict && haskey(current, Symbol(key))
            current = current[Symbol(key)]
        else
            return default
        end
    end
    return current
end

"""Get text from a runs array or text dict."""
function get_text(obj)
    obj === nothing && return nothing
    if haskey(obj, "runs") || haskey(obj, :runs)
        runs = get(obj, "runs", get(obj, :runs, nothing))
        return runs !== nothing ? join([get(r, "text", get(r, :text, "")) for r in runs], "") : nothing
    end
    return get(obj, "text", get(obj, :text, nothing))
end

"""Get thumbnail URL, preferring highest resolution."""
function get_thumbnail(item)
    thumbs = nav(item, "thumbnail", "thumbnails")
    if thumbs === nothing
        thumbs = nav(item, "thumbnail", "musicThumbnailRenderer", "thumbnail", "thumbnails")
    end
    if thumbs !== nothing && !isempty(thumbs)
        return nav(thumbs[end], "url")
    end
    return nothing
end

# Helper to safely convert to String
tostring(x) = x === nothing ? nothing : string(x)

#-----------------------------------------------------------------------------# Search
"""
    search(yt::YTMusic, query::String; filter=nothing, limit=20) -> Vector{SearchResult}

Search YouTube Music for songs, videos, albums, artists, or playlists.

# Arguments
- `yt::YTMusic`: YouTube Music client
- `query::String`: Search query
- `filter::String`: Optional filter - one of "songs", "videos", "albums", "artists", "playlists", "podcasts", "episodes"
- `limit::Int`: Maximum number of results (default: 20)

# Returns
A vector of `SearchResult` structs.

# Example
```julia
results = search("Let it Be"; filter="songs")
for r in results
    println(r.title, " by ", r.artist)
end
```
"""
function search(yt::YTMusic, query::String; filter::Maybe{String}=nothing, limit::Int=20)
    body = Dict{String,Any}("query" => query)

    if filter !== nothing
        filter in keys(SEARCH_FILTERS) || error("Invalid filter: $filter. Valid filters: $(keys(SEARCH_FILTERS))")
        body["params"] = SEARCH_FILTERS[filter]
    end

    response = send_request(yt, "search", body)
    return parse_search_results(response, limit)
end

function parse_search_results(response::Dict, limit::Int)
    results = SearchResult[]

    contents = nav(response, "contents", "tabbedSearchResultsRenderer", "tabs", 1, "tabRenderer", "content", "sectionListRenderer", "contents")
    if contents === nothing
        contents = nav(response, "contents", "sectionListRenderer", "contents")
    end
    contents === nothing && return results

    for section in contents
        shelf = nav(section, "musicShelfRenderer")
        shelf === nothing && continue

        shelf_contents = nav(shelf, "contents")
        shelf_contents === nothing && continue

        for item in shelf_contents
            length(results) >= limit && break

            renderer = nav(item, "musicResponsiveListItemRenderer")
            renderer === nothing && continue

            result = parse_search_item(renderer)
            result !== nothing && push!(results, result)
        end
    end

    return results
end

function parse_search_item(renderer::AbstractDict)
    flex_columns = nav(renderer, "flexColumns")
    flex_columns === nothing && return nothing

    title = nothing
    videoId = nothing
    browseId = nothing
    artist = nothing
    artistId = nothing
    album = nothing
    albumId = nothing
    duration = nothing

    # Get title from first flex column
    title_runs = nav(flex_columns, 1, "musicResponsiveListItemFlexColumnRenderer", "text", "runs")
    if title_runs !== nothing && !isempty(title_runs)
        title = tostring(nav(title_runs, 1, "text"))
        videoId = tostring(nav(title_runs, 1, "navigationEndpoint", "watchEndpoint", "videoId"))
        browseId = tostring(nav(title_runs, 1, "navigationEndpoint", "browseEndpoint", "browseId"))
    end

    # For albums/artists/playlists, browseId is at renderer level
    if browseId === nothing
        browseId = tostring(nav(renderer, "navigationEndpoint", "browseEndpoint", "browseId"))
    end

    # Get secondary info (artist, album, duration, etc.)
    secondary_runs = nav(flex_columns, 2, "musicResponsiveListItemFlexColumnRenderer", "text", "runs")
    if secondary_runs !== nothing
        texts = String[]
        for run in secondary_runs
            text = nav(run, "text")
            browse_id = nav(run, "navigationEndpoint", "browseEndpoint", "browseId")
            if text !== nothing && text != " • " && text != "•" && !isempty(strip(string(text)))
                push!(texts, string(text))
                if browse_id !== nothing
                    bid = string(browse_id)
                    if startswith(bid, "UC")
                        artistId = bid
                        artist = string(text)
                    elseif startswith(bid, "MPREb")
                        albumId = bid
                        album = string(text)
                    end
                end
            end
        end

        if !isempty(texts)
            if artist === nothing && length(texts) >= 1
                artist = texts[1]
            end
            if album === nothing && length(texts) >= 2 && !occursin(r"^\d+:\d+$|^\d+ min$", texts[end])
                album = texts[2]
            end
            if occursin(r"^\d+:\d+$", texts[end])
                duration = texts[end]
            end
        end
    end

    thumbnail = tostring(get_thumbnail(renderer))

    return SearchResult(; title, videoId, browseId, artist, artistId, album, albumId, duration, thumbnail)
end

#-----------------------------------------------------------------------------# Get Artist
"""
    get_artist(yt::YTMusic, channel_id::String) -> Artist

Get information about an artist.

# Arguments
- `yt::YTMusic`: YouTube Music client
- `channel_id::String`: Artist's channel ID (starts with "UC")

# Returns
An `Artist` struct containing name, description, thumbnails, and content sections.

# Example
```julia
artist = get_artist("UC2XdaAVUannpujzv32jcouQ")  # Beatles
println(artist.name)
println(keys(artist.sections))
```
"""
function get_artist(yt::YTMusic, channel_id::String)
    body = Dict{String,Any}("browseId" => channel_id)
    response = send_request(yt, "browse", body)
    return parse_artist(response)
end

function parse_artist(response::Dict)
    name = nothing
    channelId = nothing
    description = nothing
    thumbnail = nothing
    subscribers = nothing
    sections = Dict{String, Vector{ArtistItem}}()

    header = nav(response, "header", "musicImmersiveHeaderRenderer")
    if header === nothing
        header = nav(response, "header", "musicVisualHeaderRenderer")
    end

    if header !== nothing
        name = tostring(get_text(nav(header, "title")))
        description = tostring(get_text(nav(header, "description")))
        thumbnail = tostring(get_thumbnail(header))

        sub_header = nav(header, "subscriptionButton", "subscribeButtonRenderer")
        if sub_header !== nothing
            channelId = tostring(nav(sub_header, "channelId"))
            subscribers = tostring(nav(sub_header, "subscriberCountText", "runs", 1, "text"))
        end
    end

    # Parse content sections (songs, albums, etc.)
    contents = nav(response, "contents", "singleColumnBrowseResultsRenderer", "tabs", 1, "tabRenderer", "content", "sectionListRenderer", "contents")
    if contents !== nothing
        for section in contents
            shelf = nav(section, "musicShelfRenderer")
            if shelf === nothing
                shelf = nav(section, "musicCarouselShelfRenderer")
            end
            shelf === nothing && continue

            title = get_text(nav(shelf, "header", "musicCarouselShelfBasicHeaderRenderer", "title"))
            if title === nothing
                title = get_text(nav(shelf, "header", "musicShelfBasicHeaderRenderer", "title"))
            end
            title === nothing && continue

            section_key = lowercase(replace(string(title), " " => "_"))
            sections[section_key] = parse_artist_section(shelf)
        end
    end

    return Artist(; name, channelId, description, thumbnail, subscribers, sections)
end

function parse_artist_section(shelf::Dict)
    items = ArtistItem[]

    contents = nav(shelf, "contents")
    contents === nothing && return items

    for item in contents
        renderer = nav(item, "musicResponsiveListItemRenderer")
        if renderer === nothing
            renderer = nav(item, "musicTwoRowItemRenderer")
        end
        renderer === nothing && continue

        item_title = nothing
        browseId = nothing
        videoId = nothing
        item_thumbnail = nothing
        subtitle = nothing

        # For two-row items (albums, singles)
        title_text = nav(renderer, "title")
        if title_text !== nothing
            item_title = tostring(get_text(title_text))
            browseId = tostring(nav(renderer, "navigationEndpoint", "browseEndpoint", "browseId"))
        end

        # For list items (songs)
        flex_cols = nav(renderer, "flexColumns")
        if flex_cols !== nothing && !isempty(flex_cols)
            runs = nav(flex_cols, 1, "musicResponsiveListItemFlexColumnRenderer", "text", "runs")
            if runs !== nothing && !isempty(runs)
                item_title = tostring(nav(runs, 1, "text"))
                videoId = tostring(nav(runs, 1, "navigationEndpoint", "watchEndpoint", "videoId"))
            end
        end

        item_thumbnail = tostring(get_thumbnail(renderer))
        subtitle = tostring(get_text(nav(renderer, "subtitle")))

        push!(items, ArtistItem(; title=item_title, browseId, videoId, thumbnail=item_thumbnail, subtitle))
    end

    return items
end

#-----------------------------------------------------------------------------# Get Album
"""
    get_album(yt::YTMusic, browse_id::String) -> Album

Get information about an album.

# Arguments
- `yt::YTMusic`: YouTube Music client
- `browse_id::String`: Album's browse ID (starts with "MPREb")

# Returns
An `Album` struct containing title, artist, year, tracks, and more.

# Example
```julia
album = get_album("MPREb_K1pAwpWyOmq")
println(album.title, " by ", album.artist)
for track in album.tracks
    println("  ", track.trackNumber, ". ", track.title)
end
```
"""
function get_album(yt::YTMusic, browse_id::String)
    body = Dict{String,Any}("browseId" => browse_id)
    response = send_request(yt, "browse", body)
    return parse_album(response, browse_id)
end

function parse_album(response::Dict, browse_id::String)
    title = nothing
    artist = nothing
    artistId = nothing
    year = nothing
    album_type = nothing
    trackCount = nothing
    duration = nothing
    thumbnail = nothing
    description = nothing
    audioPlaylistId = nothing

    # Try different response formats
    header = nav(response, "contents", "twoColumnBrowseResultsRenderer", "tabs", 1, "tabRenderer", "content", "sectionListRenderer", "contents", 1, "musicResponsiveHeaderRenderer")
    if header === nothing
        header = nav(response, "header", "musicDetailHeaderRenderer")
    end
    if header === nothing
        header = nav(response, "header", "musicResponsiveHeaderRenderer")
    end

    if header !== nothing
        title = tostring(get_text(nav(header, "title")))

        # Get artist from straplineTextOne (new format) or subtitle
        strapline = nav(header, "straplineTextOne", "runs")
        if strapline !== nothing && !isempty(strapline)
            artist = tostring(nav(strapline, 1, "text"))
            artistId = tostring(nav(strapline, 1, "navigationEndpoint", "browseEndpoint", "browseId"))
        end

        # Get subtitle info (type, year)
        subtitle = nav(header, "subtitle", "runs")
        if subtitle !== nothing
            texts = [nav(r, "text") for r in subtitle if nav(r, "text") !== nothing && nav(r, "text") != " • "]
            if !isempty(texts)
                album_type = tostring(texts[1])
            end
            # Check subtitle for artist if not found in strapline
            if artist === nothing
                for run in subtitle
                    browse = nav(run, "navigationEndpoint", "browseEndpoint", "browseId")
                    if browse !== nothing && startswith(string(browse), "UC")
                        artistId = tostring(browse)
                        artist = tostring(nav(run, "text"))
                        break
                    end
                end
            end
            # Year is usually in the subtitle
            for text in texts
                year_match = match(r"^\d{4}$", string(text))
                if year_match !== nothing
                    year = string(text)
                    break
                end
            end
        end

        thumbnail = tostring(get_thumbnail(header))
        description = tostring(get_text(nav(header, "description")))

        # Track count and duration from secondSubtitle
        second_subtitle = nav(header, "secondSubtitle", "runs")
        if second_subtitle !== nothing
            for run in second_subtitle
                text = nav(run, "text")
                text === nothing && continue
                text_str = string(text)
                if occursin(r"^\d+ song", text_str)
                    trackCount = parse(Int, match(r"(\d+)", text_str).captures[1])
                elseif occursin(r"hour|minute", text_str)
                    duration = text_str
                end
            end
        end

        # Menu items for playlistId
        menu_items = nav(header, "menu", "menuRenderer", "items")
        if menu_items !== nothing
            for item in menu_items
                playlist_id = nav(item, "menuNavigationItemRenderer", "navigationEndpoint", "watchPlaylistEndpoint", "playlistId")
                if playlist_id !== nothing
                    audioPlaylistId = tostring(playlist_id)
                    break
                end
            end
        end
    end

    tracks = parse_album_tracks(response)

    return Album(; browseId=browse_id, title, artist, artistId, year, type=album_type, trackCount, duration, thumbnail, description, audioPlaylistId, tracks)
end

function parse_album_tracks(response::Dict)
    tracks = Track[]

    # New format: twoColumnBrowseResultsRenderer with secondaryContents
    contents = nav(response, "contents", "twoColumnBrowseResultsRenderer", "secondaryContents", "sectionListRenderer", "contents")

    # Old format: singleColumnBrowseResultsRenderer
    if contents === nothing
        contents = nav(response, "contents", "singleColumnBrowseResultsRenderer", "tabs", 1, "tabRenderer", "content", "sectionListRenderer", "contents")
    end

    contents === nothing && return tracks

    for section in contents
        shelf_contents = nav(section, "musicShelfRenderer", "contents")
        shelf_contents === nothing && continue

        for (idx, item) in enumerate(shelf_contents)
            renderer = nav(item, "musicResponsiveListItemRenderer")
            renderer === nothing && continue

            track_title = nothing
            videoId = nothing
            track_artist = nothing
            track_artistId = nothing
            track_duration = nothing
            track_thumbnail = nothing
            isAvailable = false

            flex_columns = nav(renderer, "flexColumns")
            if flex_columns !== nothing && !isempty(flex_columns)
                runs = nav(flex_columns, 1, "musicResponsiveListItemFlexColumnRenderer", "text", "runs")
                if runs !== nothing && !isempty(runs)
                    track_title = tostring(nav(runs, 1, "text"))
                    videoId = tostring(nav(runs, 1, "navigationEndpoint", "watchEndpoint", "videoId"))
                end

                if length(flex_columns) >= 2
                    artist_runs = nav(flex_columns, 2, "musicResponsiveListItemFlexColumnRenderer", "text", "runs")
                    if artist_runs !== nothing && !isempty(artist_runs)
                        track_artist = tostring(nav(artist_runs, 1, "text"))
                        track_artistId = tostring(nav(artist_runs, 1, "navigationEndpoint", "browseEndpoint", "browseId"))
                    end
                end
            end

            fixed_columns = nav(renderer, "fixedColumns")
            if fixed_columns !== nothing && !isempty(fixed_columns)
                duration_text = nav(fixed_columns, 1, "musicResponsiveListItemFixedColumnRenderer", "text")
                track_duration = tostring(get_text(duration_text))
            end

            track_thumbnail = tostring(get_thumbnail(renderer))
            isAvailable = nav(renderer, "playlistItemData", "videoId") !== nothing

            push!(tracks, Track(;
                trackNumber=idx,
                title=track_title,
                videoId,
                artist=track_artist,
                artistId=track_artistId,
                duration=track_duration,
                thumbnail=track_thumbnail,
                isAvailable
            ))
        end
    end

    return tracks
end

#-----------------------------------------------------------------------------# Get Song
"""
    get_song(yt::YTMusic, video_id::String) -> Song

Get detailed information about a song.

# Arguments
- `yt::YTMusic`: YouTube Music client
- `video_id::String`: Video ID of the song

# Returns
A `Song` struct containing title, artist, duration, and more.

# Example
```julia
song = get_song("dQw4w9WgXcQ")
println(song.title, " by ", song.artist)
println("Playable: ", song.isPlayable)
```
"""
function get_song(yt::YTMusic, video_id::String)
    body = Dict{String,Any}(
        "video_id" => video_id,
        "playbackContext" => Dict(
            "contentPlaybackContext" => Dict(
                "signatureTimestamp" => div(round(Int, time()), 86400) * 86400
            )
        )
    )

    response = send_request(yt, "player", body)
    return parse_song(response)
end

function parse_song(response::Dict)
    videoId = nothing
    title = nothing
    artist = nothing
    channelId = nothing
    lengthSeconds = nothing
    viewCount = nothing
    thumbnail = nothing
    playabilityStatus = nothing
    isPlayable = false
    category = nothing
    publishDate = nothing
    uploadDate = nothing

    video_details = nav(response, "videoDetails")
    if video_details !== nothing
        videoId = tostring(nav(video_details, "videoId"))
        title = tostring(nav(video_details, "title"))
        artist = tostring(nav(video_details, "author"))
        channelId = tostring(nav(video_details, "channelId"))
        lengthSeconds = tostring(nav(video_details, "lengthSeconds"))
        viewCount = tostring(nav(video_details, "viewCount"))

        thumbs = nav(video_details, "thumbnail", "thumbnails")
        if thumbs !== nothing && !isempty(thumbs)
            thumbnail = tostring(nav(thumbs[end], "url"))
        end
    end

    playability = nav(response, "playabilityStatus")
    if playability !== nothing
        playabilityStatus = tostring(nav(playability, "status"))
        isPlayable = nav(playability, "status") == "OK"
    end

    microformat = nav(response, "microformat", "microformatDataRenderer")
    if microformat !== nothing
        category = tostring(nav(microformat, "category"))
        publishDate = tostring(nav(microformat, "publishDate"))
        uploadDate = tostring(nav(microformat, "uploadDate"))
    end

    return Song(; videoId, title, artist, channelId, lengthSeconds, viewCount, thumbnail, playabilityStatus, isPlayable, category, publishDate, uploadDate)
end

#-----------------------------------------------------------------------------# Get Lyrics
"""
    get_lyrics(yt::YTMusic, browse_id::String) -> Lyrics

Get lyrics for a song.

# Arguments
- `yt::YTMusic`: YouTube Music client
- `browse_id::String`: Lyrics browse ID (can be obtained from watch playlist)

# Returns
A `Lyrics` struct containing the lyrics text and source.

# Example
```julia
playlist = get_watch_playlist("dQw4w9WgXcQ")
if playlist.lyricsId !== nothing
    lyrics = get_lyrics(playlist.lyricsId)
    println(lyrics.lyrics)
end
```
"""
function get_lyrics(yt::YTMusic, browse_id::String)
    body = Dict{String,Any}("browseId" => browse_id)
    response = send_request(yt, "browse", body)

    lyrics_text = nothing
    source = nothing

    contents = nav(response, "contents", "sectionListRenderer", "contents")
    if contents !== nothing && !isempty(contents)
        lyrics_renderer = nav(contents, 1, "musicDescriptionShelfRenderer")
        if lyrics_renderer !== nothing
            lyrics_text = tostring(get_text(nav(lyrics_renderer, "description")))
            source = tostring(get_text(nav(lyrics_renderer, "footer")))
        end
    end

    return Lyrics(; browseId=browse_id, lyrics=lyrics_text, source)
end

#-----------------------------------------------------------------------------# Get Watch Playlist
"""
    get_watch_playlist(yt::YTMusic, video_id::String; limit=25) -> WatchPlaylist

Get the watch playlist (queue) for a video, which includes related tracks and lyrics browse ID.

# Arguments
- `yt::YTMusic`: YouTube Music client
- `video_id::String`: Video ID to get playlist for
- `limit::Int`: Maximum number of tracks to return (default: 25)

# Returns
A `WatchPlaylist` struct containing tracks and lyrics browse ID if available.

# Example
```julia
playlist = get_watch_playlist("dQw4w9WgXcQ")
for track in playlist.tracks
    println(track.title, " by ", track.artist)
end
```
"""
function get_watch_playlist(yt::YTMusic, video_id::String; limit::Int=25)
    body = Dict{String,Any}(
        "enablePersistentPlaylistPanel" => true,
        "tunerSettingValue" => "AUTOMIX_SETTING_NORMAL",
        "videoId" => video_id,
        "playlistId" => "RDAMVM$video_id",
        "watchEndpointMusicSupportedConfigs" => Dict(
            "watchEndpointMusicConfig" => Dict(
                "musicVideoType" => "MUSIC_VIDEO_TYPE_ATV"
            )
        ),
        "isAudioOnly" => true
    )

    response = send_request(yt, "next", body)
    return parse_watch_playlist(response, limit)
end

function parse_watch_playlist(response::Dict, limit::Int)
    playlistId = nothing
    tracks = PlaylistTrack[]
    lyricsId = nothing

    panel = nav(response, "contents", "singleColumnMusicWatchNextResultsRenderer", "tabbedRenderer", "watchNextTabbedResultsRenderer", "tabs", 1, "tabRenderer", "content", "musicQueueRenderer", "content", "playlistPanelRenderer")

    if panel !== nothing
        playlistId = tostring(nav(panel, "playlistId"))

        contents = nav(panel, "contents")
        if contents !== nothing
            for item in contents
                length(tracks) >= limit && break

                renderer = nav(item, "playlistPanelVideoRenderer")
                renderer === nothing && continue

                track_videoId = tostring(nav(renderer, "videoId"))
                track_title = tostring(get_text(nav(renderer, "title")))
                track_artist = nothing
                track_artistId = nothing
                track_duration = tostring(get_text(nav(renderer, "lengthText")))
                track_thumbnail = tostring(get_thumbnail(renderer))

                byline = nav(renderer, "longBylineText", "runs")
                if byline !== nothing && !isempty(byline)
                    track_artist = tostring(nav(byline, 1, "text"))
                    track_artistId = tostring(nav(byline, 1, "navigationEndpoint", "browseEndpoint", "browseId"))
                end

                push!(tracks, PlaylistTrack(;
                    videoId=track_videoId,
                    title=track_title,
                    artist=track_artist,
                    artistId=track_artistId,
                    duration=track_duration,
                    thumbnail=track_thumbnail
                ))
            end
        end
    end

    # Get lyrics browse ID from tabs
    tabs = nav(response, "contents", "singleColumnMusicWatchNextResultsRenderer", "tabbedRenderer", "watchNextTabbedResultsRenderer", "tabs")
    if tabs !== nothing && length(tabs) >= 2
        lyricsId = tostring(nav(tabs, 2, "tabRenderer", "endpoint", "browseEndpoint", "browseId"))
    end

    return WatchPlaylist(; playlistId, tracks, lyricsId)
end

#-----------------------------------------------------------------------------# Convenience methods using global `yt`
"""
    search(query::String; filter=nothing, limit=20) -> Vector{SearchResult}

Search YouTube Music using the global client.
"""
search(query::String; filter::Maybe{String}=nothing, limit::Int=20) = search(yt[], query; filter, limit)

"""
    get_artist(channel_id::String) -> Artist

Get artist info using the global client.
"""
get_artist(channel_id::String) = get_artist(yt[], channel_id)

"""
    get_album(browse_id::String) -> Album

Get album info using the global client.
"""
get_album(browse_id::String) = get_album(yt[], browse_id)

"""
    get_song(video_id::String) -> Song

Get song info using the global client.
"""
get_song(video_id::String) = get_song(yt[], video_id)

"""
    get_lyrics(browse_id::String) -> Lyrics

Get lyrics using the global client.
"""
get_lyrics(browse_id::String) = get_lyrics(yt[], browse_id)

"""
    get_watch_playlist(video_id::String; limit=25) -> WatchPlaylist

Get watch playlist using the global client.
"""
get_watch_playlist(video_id::String; limit::Int=25) = get_watch_playlist(yt[], video_id; limit)

#-----------------------------------------------------------------------------# Constructors from SearchResult
"""
    Song(result::SearchResult) -> Song

Fetch full song details from a search result. Errors if the result doesn't have a videoId.

# Example
```julia
results = search("Yesterday"; filter="songs", limit=1)
song = Song(results[1])
```
"""
function Song(result::SearchResult)
    result.videoId === nothing && error("SearchResult does not have a videoId. Cannot fetch Song.")
    return get_song(result.videoId)
end

"""
    Album(result::SearchResult) -> Album

Fetch full album details from a search result. Errors if the result doesn't have an album browseId.

# Example
```julia
results = search("Abbey Road"; filter="albums", limit=1)
album = Album(results[1])
```
"""
function Album(result::SearchResult)
    bid = result.browseId
    if bid === nothing || !startswith(bid, "MPREb")
        error("SearchResult does not have an album browseId (starting with 'MPREb'). Cannot fetch Album.")
    end
    return get_album(bid)
end

"""
    Artist(result::SearchResult) -> Artist

Fetch full artist details from a search result. Errors if the result doesn't have an artist browseId.

# Example
```julia
results = search("Beatles"; filter="artists", limit=1)
artist = Artist(results[1])
```
"""
function Artist(result::SearchResult)
    # First check if this is an artist result (browseId starts with UC)
    if result.browseId !== nothing && startswith(result.browseId, "UC")
        return get_artist(result.browseId)
    end
    # Otherwise try to get artist from artistId field
    if result.artistId !== nothing
        return get_artist(result.artistId)
    end
    error("SearchResult does not have an artist browseId or artistId. Cannot fetch Artist.")
end

"""
    Artist(song::Song) -> Artist

Fetch the artist of a song. Errors if the song doesn't have a channelId.

# Example
```julia
song = get_song("dQw4w9WgXcQ")
artist = Artist(song)
```
"""
function Artist(song::Song)
    song.channelId === nothing && error("Song does not have a channelId. Cannot fetch Artist.")
    return get_artist(song.channelId)
end

"""
    Artist(album::Album) -> Artist

Fetch the artist of an album. Errors if the album doesn't have an artistId.

# Example
```julia
album = get_album("MPREb_...")
artist = Artist(album)
```
"""
function Artist(album::Album)
    album.artistId === nothing && error("Album does not have an artistId. Cannot fetch Artist.")
    return get_artist(album.artistId)
end

"""
    Artist(track::Track) -> Artist

Fetch the artist of an album track. Errors if the track doesn't have an artistId.
"""
function Artist(track::Track)
    track.artistId === nothing && error("Track does not have an artistId. Cannot fetch Artist.")
    return get_artist(track.artistId)
end

"""
    Artist(track::PlaylistTrack) -> Artist

Fetch the artist of a playlist track. Errors if the track doesn't have an artistId.
"""
function Artist(track::PlaylistTrack)
    track.artistId === nothing && error("PlaylistTrack does not have an artistId. Cannot fetch Artist.")
    return get_artist(track.artistId)
end

"""
    Artist(item::ArtistItem) -> Artist

Fetch artist details from an artist item. Errors if the item doesn't have a browseId starting with "UC".
"""
function Artist(item::ArtistItem)
    if item.browseId !== nothing && startswith(item.browseId, "UC")
        return get_artist(item.browseId)
    end
    error("ArtistItem does not have an artist browseId (starting with 'UC'). Cannot fetch Artist.")
end

"""
    WatchPlaylist(result::SearchResult; limit=25) -> WatchPlaylist

Fetch watch playlist from a search result. Errors if the result doesn't have a videoId.

# Example
```julia
results = search("Yesterday"; filter="songs", limit=1)
playlist = WatchPlaylist(results[1])
```
"""
function WatchPlaylist(result::SearchResult; limit::Int=25)
    result.videoId === nothing && error("SearchResult does not have a videoId. Cannot fetch WatchPlaylist.")
    return get_watch_playlist(result.videoId; limit)
end

#-----------------------------------------------------------------------------# Authenticated Library Functions
"""
    get_library_playlists(yt::YTMusic; limit=25) -> Vector{Playlist}

Get user's library playlists. Requires authentication.
Uses the official YouTube Data API.

# Example
```julia
yt = YTMusic("oauth.json")
playlists = get_library_playlists(yt)
for p in playlists
    println(p.title, " (", p.trackCount, " tracks)")
end
```
"""
function get_library_playlists(yt::YTMusic; limit::Int=25)
    playlists = Playlist[]
    page_token = nothing

    while length(playlists) < limit
        params = Dict{String,String}(
            "part" => "snippet,contentDetails",
            "mine" => "true",
            "maxResults" => string(min(50, limit - length(playlists)))
        )
        if page_token !== nothing
            params["pageToken"] = page_token
        end

        response = send_data_api_request(yt, "playlists"; params)

        items = get(response, "items", [])
        for item in items
            length(playlists) >= limit && break

            snippet = get(item, "snippet", Dict())
            content_details = get(item, "contentDetails", Dict())
            thumbnails = get(snippet, "thumbnails", Dict())
            thumb = get(thumbnails, "high", get(thumbnails, "default", Dict()))

            push!(playlists, Playlist(
                playlistId = tostring(get(item, "id", nothing)),
                title = tostring(get(snippet, "title", nothing)),
                description = tostring(get(snippet, "description", nothing)),
                thumbnail = tostring(get(thumb, "url", nothing)),
                trackCount = get(content_details, "itemCount", nothing),
                author = tostring(get(snippet, "channelTitle", nothing))
            ))
        end

        # Check for next page
        page_token = get(response, "nextPageToken", nothing)
        page_token === nothing && break
    end

    return playlists
end

"""
    get_library_songs(yt::YTMusic; limit=25) -> Vector{LibraryItem}

Get user's liked songs from library. Requires authentication.
Uses the official YouTube Data API to get liked videos.

# Example
```julia
yt = YTMusic("oauth.json")
songs = get_library_songs(yt; limit=50)
for s in songs
    println(s.title, " by ", s.artist)
end
```
"""
function get_library_songs(yt::YTMusic; limit::Int=25)
    songs = LibraryItem[]
    page_token = nothing

    while length(songs) < limit
        params = Dict{String,String}(
            "part" => "snippet,contentDetails",
            "myRating" => "like",
            "maxResults" => string(min(50, limit - length(songs)))
        )
        if page_token !== nothing
            params["pageToken"] = page_token
        end

        response = send_data_api_request(yt, "videos"; params)

        items = get(response, "items", [])
        for item in items
            length(songs) >= limit && break

            snippet = get(item, "snippet", Dict())
            content_details = get(item, "contentDetails", Dict())
            thumbnails = get(snippet, "thumbnails", Dict())
            thumb = get(thumbnails, "high", get(thumbnails, "default", Dict()))

            # Parse duration from ISO 8601 format (PT#M#S)
            duration_iso = tostring(get(content_details, "duration", nothing))
            duration = nothing
            if duration_iso !== nothing
                m = match(r"PT(?:(\d+)H)?(?:(\d+)M)?(?:(\d+)S)?", duration_iso)
                if m !== nothing
                    h = m.captures[1] !== nothing ? parse(Int, m.captures[1]) : 0
                    mins = m.captures[2] !== nothing ? parse(Int, m.captures[2]) : 0
                    s = m.captures[3] !== nothing ? parse(Int, m.captures[3]) : 0
                    if h > 0
                        duration = string(h, ":", lpad(mins, 2, '0'), ":", lpad(s, 2, '0'))
                    else
                        duration = string(mins, ":", lpad(s, 2, '0'))
                    end
                end
            end

            push!(songs, LibraryItem(
                title = tostring(get(snippet, "title", nothing)),
                videoId = tostring(get(item, "id", nothing)),
                artist = tostring(get(snippet, "channelTitle", nothing)),
                thumbnail = tostring(get(thumb, "url", nothing)),
                duration = duration,
                likeStatus = "LIKE"
            ))
        end

        # Check for next page
        page_token = get(response, "nextPageToken", nothing)
        page_token === nothing && break
    end

    return songs
end

"""
    get_library_albums(yt::YTMusic; limit=25) -> Vector{LibraryItem}

Get user's saved albums from library.

Note: This function requires access to YouTube Music's internal API, which may not work
with all OAuth configurations. If you get errors, try publishing your OAuth app in
Google Cloud Console or use `get_library_playlists()` and `get_library_songs()` instead.
"""
function get_library_albums(yt::YTMusic; limit::Int=25)
    error("get_library_albums is not available via the YouTube Data API. " *
          "To use this function, your OAuth app may need to be published in Google Cloud Console. " *
          "Use get_library_playlists() or get_library_songs() instead.")
end

"""
    get_library_artists(yt::YTMusic; limit=25) -> Vector{LibraryItem}

Get user's followed artists from library.

Note: This function requires access to YouTube Music's internal API, which may not work
with all OAuth configurations. If you get errors, try publishing your OAuth app in
Google Cloud Console or use `get_library_playlists()` and `get_library_songs()` instead.
"""
function get_library_artists(yt::YTMusic; limit::Int=25)
    error("get_library_artists is not available via the YouTube Data API. " *
          "To use this function, your OAuth app may need to be published in Google Cloud Console. " *
          "Use get_library_playlists() or get_library_songs() instead.")
end

"""
    get_liked_songs(yt::YTMusic; limit=25) -> Vector{LibraryItem}

Get user's liked songs. Alias for `get_library_songs`. Requires authentication.
"""
get_liked_songs(yt::YTMusic; limit::Int=25) = get_library_songs(yt; limit)

"""
    get_history(yt::YTMusic; limit=25) -> Vector{LibraryItem}

Get user's recently played songs.

Note: This function requires access to YouTube Music's internal API, which may not work
with all OAuth configurations. If you get errors, try publishing your OAuth app in
Google Cloud Console or use `get_library_playlists()` and `get_library_songs()` instead.
"""
function get_history(yt::YTMusic; limit::Int=25)
    error("get_history is not available via the YouTube Data API. " *
          "To use this function, your OAuth app may need to be published in Google Cloud Console. " *
          "Use get_library_playlists() or get_library_songs() instead.")
end

function parse_library_items(response::Dict, limit::Int)
    items = LibraryItem[]

    contents = nav(response, "contents", "singleColumnBrowseResultsRenderer", "tabs", 1, "tabRenderer", "content", "sectionListRenderer", "contents")
    contents === nothing && return items

    for section in contents
        shelf = nav(section, "musicShelfRenderer")
        if shelf === nothing
            shelf = nav(section, "gridRenderer")
        end
        shelf === nothing && continue

        shelf_contents = nav(shelf, "contents")
        if shelf_contents === nothing
            shelf_contents = nav(shelf, "items")
        end
        shelf_contents === nothing && continue

        for item in shelf_contents
            length(items) >= limit && break

            renderer = nav(item, "musicResponsiveListItemRenderer")
            if renderer === nothing
                renderer = nav(item, "musicTwoRowItemRenderer")
            end
            renderer === nothing && continue

            lib_item = parse_library_item(renderer)
            lib_item !== nothing && push!(items, lib_item)
        end
    end

    return items
end

function parse_library_item(renderer::AbstractDict)
    title = nothing
    videoId = nothing
    browseId = nothing
    playlistId = nothing
    artist = nothing
    artistId = nothing
    album = nothing
    albumId = nothing
    duration = nothing
    thumbnail = nothing
    likeStatus = nothing

    # Handle musicTwoRowItemRenderer (albums, artists in grid)
    title_obj = nav(renderer, "title")
    if title_obj !== nothing
        title = tostring(get_text(title_obj))
        browseId = tostring(nav(renderer, "navigationEndpoint", "browseEndpoint", "browseId"))
    end

    # Handle musicResponsiveListItemRenderer (songs, history)
    flex_columns = nav(renderer, "flexColumns")
    if flex_columns !== nothing && !isempty(flex_columns)
        runs = nav(flex_columns, 1, "musicResponsiveListItemFlexColumnRenderer", "text", "runs")
        if runs !== nothing && !isempty(runs)
            title = tostring(nav(runs, 1, "text"))
            videoId = tostring(nav(runs, 1, "navigationEndpoint", "watchEndpoint", "videoId"))
            playlistId = tostring(nav(runs, 1, "navigationEndpoint", "watchEndpoint", "playlistId"))
        end

        # Artist and album from second column
        if length(flex_columns) >= 2
            secondary_runs = nav(flex_columns, 2, "musicResponsiveListItemFlexColumnRenderer", "text", "runs")
            if secondary_runs !== nothing
                for run in secondary_runs
                    text = nav(run, "text")
                    text === nothing && continue
                    text_str = string(text)
                    text_str in [" • ", "•", " & ", "&"] && continue

                    browse_id = nav(run, "navigationEndpoint", "browseEndpoint", "browseId")
                    if browse_id !== nothing
                        bid = string(browse_id)
                        if startswith(bid, "UC")
                            artistId = bid
                            artist = text_str
                        elseif startswith(bid, "MPREb")
                            albumId = bid
                            album = text_str
                        end
                    elseif artist === nothing
                        artist = text_str
                    end
                end
            end
        end
    end

    # Fixed columns for duration
    fixed_columns = nav(renderer, "fixedColumns")
    if fixed_columns !== nothing && !isempty(fixed_columns)
        duration_text = nav(fixed_columns, 1, "musicResponsiveListItemFixedColumnRenderer", "text")
        duration = tostring(get_text(duration_text))
    end

    # Subtitle for two-row items
    subtitle = get_text(nav(renderer, "subtitle"))
    if subtitle !== nothing && artist === nothing
        artist = string(subtitle)
    end

    thumbnail = tostring(get_thumbnail(renderer))

    # Like status
    menu_items = nav(renderer, "menu", "menuRenderer", "items")
    if menu_items !== nothing
        for menu_item in menu_items
            toggle = nav(menu_item, "menuServiceItemRenderer", "icon", "iconType")
            if toggle !== nothing
                toggle_str = string(toggle)
                if toggle_str == "LIKE" || toggle_str == "DISLIKE"
                    likeStatus = toggle_str
                    break
                end
            end
        end
    end

    return LibraryItem(; title, videoId, browseId, playlistId, artist, artistId, album, albumId, duration, thumbnail, likeStatus)
end

#-----------------------------------------------------------------------------# Playlist Management Functions (Authenticated)
"""
    create_playlist(yt::YTMusic, title::String; description="", privacy="PRIVATE") -> String

Create a new playlist. Returns the playlist ID.

# Arguments
- `yt::YTMusic`: Authenticated YouTube Music client
- `title::String`: Playlist title
- `description::String`: Playlist description (default: "")
- `privacy::String`: Privacy setting - "PRIVATE", "PUBLIC", or "UNLISTED" (default: "PRIVATE")

# Returns
The playlist ID of the newly created playlist.

# Example
```julia
yt = YTMusic("oauth.json")
playlist_id = create_playlist(yt, "My Favorites"; description="Best songs", privacy="PRIVATE")
```
"""
function create_playlist(yt::YTMusic, title::String; description::String="", privacy::String="PRIVATE")
    privacy in ["PRIVATE", "PUBLIC", "UNLISTED"] || error("Invalid privacy setting: $privacy. Must be PRIVATE, PUBLIC, or UNLISTED.")

    body = Dict{String,Any}(
        "title" => title,
        "description" => description,
        "privacyStatus" => privacy
    )

    response = send_request(yt, "playlist/create", body; require_authentication=true)

    playlist_id = nav(response, "playlistId")
    playlist_id === nothing && error("Failed to create playlist: no playlistId in response")

    return string(playlist_id)
end

"""
    add_playlist_items(yt::YTMusic, playlist_id::String, video_ids::Vector{String}) -> Dict

Add songs to a playlist. Returns status information.

# Arguments
- `yt::YTMusic`: Authenticated YouTube Music client
- `playlist_id::String`: The playlist ID to add songs to
- `video_ids::Vector{String}`: Video IDs of songs to add

# Example
```julia
yt = YTMusic("oauth.json")
add_playlist_items(yt, "PLxxxxx", ["dQw4w9WgXcQ", "abc123def"])
```
"""
function add_playlist_items(yt::YTMusic, playlist_id::String, video_ids::Vector{String})
    isempty(video_ids) && return Dict("status" => "SUCCESS", "playlistEditResults" => [])

    actions = [
        Dict{String,Any}(
            "action" => "ACTION_ADD_VIDEO",
            "addedVideoId" => vid
        ) for vid in video_ids
    ]

    body = Dict{String,Any}(
        "playlistId" => playlist_id,
        "actions" => actions
    )

    response = send_request(yt, "browse/edit_playlist", body; require_authentication=true)

    status = tostring(nav(response, "status"))
    results = nav(response, "playlistEditResults")

    return Dict(
        "status" => status === nothing ? "UNKNOWN" : status,
        "playlistEditResults" => results === nothing ? [] : results
    )
end

"""
    add_playlist_items(yt::YTMusic, playlist_id::String, video_id::String) -> Dict

Add a single song to a playlist. Convenience method for single video.
"""
add_playlist_items(yt::YTMusic, playlist_id::String, video_id::String) = add_playlist_items(yt, playlist_id, [video_id])

"""
    remove_playlist_items(yt::YTMusic, playlist_id::String, video_ids::Vector{String}) -> Dict

Remove songs from a playlist.

Note: This requires the `setVideoId` which is different from the regular `videoId`.
You can get `setVideoId` from the playlist contents via `get_playlist`.

# Arguments
- `yt::YTMusic`: Authenticated YouTube Music client
- `playlist_id::String`: The playlist ID to remove songs from
- `video_ids::Vector{String}`: Video IDs of songs to remove (these are setVideoIds from the playlist)

# Example
```julia
yt = YTMusic("oauth.json")
playlist = get_playlist(yt, "PLxxxxx")
# Get setVideoIds from playlist tracks
set_video_ids = [t.setVideoId for t in playlist.tracks if t.setVideoId !== nothing]
remove_playlist_items(yt, "PLxxxxx", set_video_ids[1:2])
```
"""
function remove_playlist_items(yt::YTMusic, playlist_id::String, video_ids::Vector{String})
    isempty(video_ids) && return Dict("status" => "SUCCESS", "playlistEditResults" => [])

    actions = [
        Dict{String,Any}(
            "action" => "ACTION_REMOVE_VIDEO",
            "setVideoId" => vid
        ) for vid in video_ids
    ]

    body = Dict{String,Any}(
        "playlistId" => playlist_id,
        "actions" => actions
    )

    response = send_request(yt, "browse/edit_playlist", body; require_authentication=true)

    status = tostring(nav(response, "status"))
    results = nav(response, "playlistEditResults")

    return Dict(
        "status" => status === nothing ? "UNKNOWN" : status,
        "playlistEditResults" => results === nothing ? [] : results
    )
end

"""
    remove_playlist_items(yt::YTMusic, playlist_id::String, video_id::String) -> Dict

Remove a single song from a playlist. Convenience method for single video.
"""
remove_playlist_items(yt::YTMusic, playlist_id::String, video_id::String) = remove_playlist_items(yt, playlist_id, [video_id])

"""
    delete_playlist(yt::YTMusic, playlist_id::String) -> Bool

Delete a playlist. Returns true if successful.

# Arguments
- `yt::YTMusic`: Authenticated YouTube Music client
- `playlist_id::String`: The playlist ID to delete

# Example
```julia
yt = YTMusic("oauth.json")
delete_playlist(yt, "PLxxxxx")
```
"""
function delete_playlist(yt::YTMusic, playlist_id::String)
    body = Dict{String,Any}("playlistId" => playlist_id)

    response = send_request(yt, "playlist/delete", body; require_authentication=true)

    # The API returns an empty response on success
    return true
end

"""
    get_playlist(yt::YTMusic, playlist_id::String; limit=100) -> NamedTuple

Get playlist contents with full track details including setVideoId (needed for removal).

# Arguments
- `yt::YTMusic`: YouTube Music client
- `playlist_id::String`: The playlist ID (or browse ID starting with "VL")
- `limit::Int`: Maximum number of tracks to return (default: 100)

# Returns
A NamedTuple with fields: `playlistId`, `title`, `description`, `trackCount`, `tracks`

Each track in `tracks` is a NamedTuple with: `videoId`, `setVideoId`, `title`, `artist`, `artistId`, `album`, `albumId`, `duration`, `thumbnail`

# Example
```julia
playlist = get_playlist(yt, "PLxxxxx")
println(playlist.title)
for track in playlist.tracks
    println(track.title, " by ", track.artist)
end
```
"""
function get_playlist(yt::YTMusic, playlist_id::String; limit::Int=100)
    # Ensure browse ID format
    browse_id = startswith(playlist_id, "VL") ? playlist_id : "VL" * playlist_id

    body = Dict{String,Any}("browseId" => browse_id)
    response = send_request(yt, "browse", body; require_authentication=is_authenticated(yt))

    return parse_playlist_contents(response, limit)
end

function parse_playlist_contents(response::Dict, limit::Int)
    playlist_id = nothing
    title = nothing
    description = nothing
    track_count = nothing
    tracks = NamedTuple[]

    # Get header info
    header = nav(response, "header", "musicDetailHeaderRenderer")
    if header === nothing
        header = nav(response, "header", "musicEditablePlaylistDetailHeaderRenderer", "header", "musicDetailHeaderRenderer")
    end

    if header !== nothing
        title = tostring(get_text(nav(header, "title")))
        description = tostring(get_text(nav(header, "description")))

        # Extract track count from subtitle
        subtitle = nav(header, "subtitle", "runs")
        if subtitle !== nothing
            for run in subtitle
                text = nav(run, "text")
                text === nothing && continue
                m = match(r"(\d+)\s*(?:song|track)", string(text))
                if m !== nothing
                    track_count = parse(Int, m.captures[1])
                    break
                end
            end
        end

        # Get menu for playlistId
        menu = nav(header, "menu", "menuRenderer", "items")
        if menu !== nothing
            for item in menu
                pid = nav(item, "menuNavigationItemRenderer", "navigationEndpoint", "watchPlaylistEndpoint", "playlistId")
                if pid !== nothing
                    playlist_id = tostring(pid)
                    break
                end
            end
        end
    end

    # Parse tracks
    contents = nav(response, "contents", "singleColumnBrowseResultsRenderer", "tabs", 1, "tabRenderer", "content", "sectionListRenderer", "contents")
    contents === nothing && return (playlistId=playlist_id, title=title, description=description, trackCount=track_count, tracks=tracks)

    for section in contents
        shelf = nav(section, "musicPlaylistShelfRenderer")
        if shelf === nothing
            shelf = nav(section, "musicShelfRenderer")
        end
        shelf === nothing && continue

        if playlist_id === nothing
            playlist_id = tostring(nav(shelf, "playlistId"))
        end

        shelf_contents = nav(shelf, "contents")
        shelf_contents === nothing && continue

        for item in shelf_contents
            length(tracks) >= limit && break

            renderer = nav(item, "musicResponsiveListItemRenderer")
            renderer === nothing && continue

            track = parse_playlist_track_with_set_id(renderer)
            track !== nothing && push!(tracks, track)
        end
    end

    return (playlistId=playlist_id, title=title, description=description, trackCount=track_count, tracks=tracks)
end

function parse_playlist_track_with_set_id(renderer::AbstractDict)
    videoId = nothing
    setVideoId = nothing
    title = nothing
    artist = nothing
    artistId = nothing
    album = nothing
    albumId = nothing
    duration = nothing
    thumbnail = nothing

    # Get setVideoId from playlistItemData
    setVideoId = tostring(nav(renderer, "playlistItemData", "playlistSetVideoId"))
    videoId = tostring(nav(renderer, "playlistItemData", "videoId"))

    flex_columns = nav(renderer, "flexColumns")
    if flex_columns !== nothing && !isempty(flex_columns)
        # Title from first column
        runs = nav(flex_columns, 1, "musicResponsiveListItemFlexColumnRenderer", "text", "runs")
        if runs !== nothing && !isempty(runs)
            title = tostring(nav(runs, 1, "text"))
            if videoId === nothing
                videoId = tostring(nav(runs, 1, "navigationEndpoint", "watchEndpoint", "videoId"))
            end
        end

        # Artist and album from second column
        if length(flex_columns) >= 2
            secondary_runs = nav(flex_columns, 2, "musicResponsiveListItemFlexColumnRenderer", "text", "runs")
            if secondary_runs !== nothing
                for run in secondary_runs
                    text = nav(run, "text")
                    text === nothing && continue
                    text_str = string(text)
                    text_str in [" • ", "•", " & ", "&"] && continue

                    browse_id = nav(run, "navigationEndpoint", "browseEndpoint", "browseId")
                    if browse_id !== nothing
                        bid = string(browse_id)
                        if startswith(bid, "UC")
                            artistId = bid
                            artist = text_str
                        elseif startswith(bid, "MPREb")
                            albumId = bid
                            album = text_str
                        end
                    elseif artist === nothing
                        artist = text_str
                    end
                end
            end
        end
    end

    # Duration from fixed columns
    fixed_columns = nav(renderer, "fixedColumns")
    if fixed_columns !== nothing && !isempty(fixed_columns)
        duration_text = nav(fixed_columns, 1, "musicResponsiveListItemFixedColumnRenderer", "text")
        duration = tostring(get_text(duration_text))
    end

    thumbnail = tostring(get_thumbnail(renderer))

    return (videoId=videoId, setVideoId=setVideoId, title=title, artist=artist, artistId=artistId, album=album, albumId=albumId, duration=duration, thumbnail=thumbnail)
end

#-----------------------------------------------------------------------------# Convenience methods for playlist management using global `yt`
"""
    create_playlist(title::String; description="", privacy="PRIVATE") -> String

Create a new playlist using the global client.
"""
create_playlist(title::String; description::String="", privacy::String="PRIVATE") = create_playlist(yt[], title; description, privacy)

"""
    add_playlist_items(playlist_id::String, video_ids) -> Dict

Add songs to a playlist using the global client.
"""
add_playlist_items(playlist_id::String, video_ids::Vector{String}) = add_playlist_items(yt[], playlist_id, video_ids)
add_playlist_items(playlist_id::String, video_id::String) = add_playlist_items(yt[], playlist_id, video_id)

"""
    remove_playlist_items(playlist_id::String, video_ids) -> Dict

Remove songs from a playlist using the global client.
"""
remove_playlist_items(playlist_id::String, video_ids::Vector{String}) = remove_playlist_items(yt[], playlist_id, video_ids)
remove_playlist_items(playlist_id::String, video_id::String) = remove_playlist_items(yt[], playlist_id, video_id)

"""
    delete_playlist(playlist_id::String) -> Bool

Delete a playlist using the global client.
"""
delete_playlist(playlist_id::String) = delete_playlist(yt[], playlist_id)

"""
    get_playlist(playlist_id::String; limit=100) -> NamedTuple

Get playlist contents using the global client.
"""
get_playlist(playlist_id::String; limit::Int=100) = get_playlist(yt[], playlist_id; limit)

#-----------------------------------------------------------------------------# Convenience methods for library functions using global `yt`
"""
    get_library_playlists(; limit=25) -> Vector{Playlist}

Get user's library playlists using the global client.
"""
get_library_playlists(; limit::Int=25) = get_library_playlists(yt[]; limit)

"""
    get_library_songs(; limit=25) -> Vector{LibraryItem}

Get user's liked songs using the global client.
"""
get_library_songs(; limit::Int=25) = get_library_songs(yt[]; limit)

"""
    get_library_albums(; limit=25) -> Vector{LibraryItem}

Get user's saved albums using the global client.
"""
get_library_albums(; limit::Int=25) = get_library_albums(yt[]; limit)

"""
    get_library_artists(; limit=25) -> Vector{LibraryItem}

Get user's followed artists using the global client.
"""
get_library_artists(; limit::Int=25) = get_library_artists(yt[]; limit)

"""
    get_liked_songs(; limit=25) -> Vector{LibraryItem}

Get user's liked songs using the global client.
"""
get_liked_songs(; limit::Int=25) = get_liked_songs(yt[]; limit)

"""
    get_history(; limit=25) -> Vector{LibraryItem}

Get user's recently played songs using the global client.
"""
get_history(; limit::Int=25) = get_history(yt[]; limit)

end # module
