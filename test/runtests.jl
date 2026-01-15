using YTMusicAPI
using Test

@testset "YTMusicAPI.jl" begin
    @testset "YTMusic client creation" begin
        yt = YTMusic()
        @test yt.language == "en"
        @test yt.location == "US"
        @test !isempty(yt.headers)
        @test haskey(yt.context, "client")

        # Test with different language/location
        yt2 = YTMusic(language="de", location="DE")
        @test yt2.language == "de"
        @test yt2.location == "DE"

        # Test invalid language
        @test_throws ErrorException YTMusic(language="invalid")
        @test_throws ErrorException YTMusic(location="invalid")
    end

    @testset "Search functionality" begin
        # Basic search
        results = search("Beatles"; limit=5)
        @test results isa Vector{SearchResult}
        @test length(results) > 0
        @test length(results) <= 5
        @test results[1].title !== nothing

        # Search with filter - songs
        songs = search("Let it Be Beatles"; filter="songs", limit=3)
        @test length(songs) > 0
        @test all(s -> s.videoId !== nothing, songs)

        # Search with filter - albums
        albums = search("Abbey Road"; filter="albums", limit=3)
        @test length(albums) > 0

        # Search with filter - artists
        artists = search("Beatles"; filter="artists", limit=3)
        @test length(artists) > 0

        # Test invalid filter
        @test_throws ErrorException search("test"; filter="invalid_filter")
    end

    @testset "Get song" begin
        # Get song details
        song = get_song("HzvDofigTKQ")  # Let it Be
        @test song isa Song
        @test song.title !== nothing
        @test song.videoId == "HzvDofigTKQ"
        @test song.artist !== nothing
        @test song.isPlayable isa Bool
    end

    @testset "Get album" begin
        # First search for an album to get its browseId
        results = search("Abbey Road Beatles"; filter="albums", limit=1)
        @test length(results) > 0
        @test results[1].browseId !== nothing

        # Get album details
        album = get_album(results[1].browseId)
        @test album isa Album
        @test album.title !== nothing
        @test album.artist !== nothing
        @test album.tracks isa Vector{Track}
        @test length(album.tracks) > 0
        @test album.tracks[1].title !== nothing
    end

    @testset "Get artist" begin
        # Search for an artist to get channel ID
        results = search("Beatles"; filter="artists", limit=1)
        @test length(results) > 0
        @test results[1].browseId !== nothing

        # Get artist details
        artist = get_artist(results[1].browseId)
        @test artist isa Artist
        @test artist.name !== nothing
        @test artist.name == "The Beatles"
        @test artist.sections isa Dict{String, Vector{ArtistItem}}
    end

    @testset "Watch playlist and lyrics" begin
        # Get watch playlist
        playlist = get_watch_playlist("HzvDofigTKQ"; limit=5)
        @test playlist isa WatchPlaylist
        @test playlist.tracks isa Vector{PlaylistTrack}
        @test length(playlist.tracks) > 0
        @test playlist.tracks[1].title !== nothing

        # Get lyrics if available
        if playlist.lyricsId !== nothing
            lyrics = get_lyrics(playlist.lyricsId)
            @test lyrics isa Lyrics
            @test lyrics.browseId !== nothing
        end
    end
end
