using System.Text.Json;
using System.Text.Json.Serialization;

namespace VibeLightHelper.Core;

/// <summary>
/// The wire contract with VibeLight (VibeLight/Core/WindowsHelperClient.swift).
/// HTTPS on <see cref="DefaultPort"/>, one request per connection, JSON bodies.
/// Every route but /info needs the device's GameStream client certificate in
/// the TLS handshake (see <see cref="TrustedClients"/>): no pairing of its own.
/// </summary>
public static class Protocol
{
    public const int DefaultPort = 47333;
    public const string Version = "1.0";

    public static readonly JsonSerializerOptions Json = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
    };
}

public sealed record InfoResponse(string Name, string Version, string HostName);

public sealed record DisplayInfo(string Device, int Width, int Height, int RefreshHz);

public sealed record GameInfo(string Title, string Process, bool ExclusiveFullscreen);

public sealed record StatusResponse(DisplayInfo? Display, GameInfo? Game, bool Matched);

/// <summary>POST /match: the size the stream now has, which the PC's display
/// and the game should take on.</summary>
public sealed record MatchRequest(int Width, int Height);

/// <summary>What /match and /restore did. <c>Message</c> is a short human line
/// VibeLight can show as is.</summary>
public sealed record MatchResponse(bool Ok, DisplayInfo? Display, GameInfo? Game, bool GameFitted, string Message);

public sealed record QuitGameRequest(int? GraceSeconds);

public sealed record QuitGameResponse(bool Ok, string? Title, bool Forced, string Message);

public sealed record ErrorResponse(string Error);
