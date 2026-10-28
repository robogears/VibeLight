using System.Text.Json;

namespace VibeLightHelper.Core;

/// <summary>The routes. Transport-free (the server hands it a parsed request
/// and the client's certificate), so the whole API is tested without a socket.</summary>
public sealed class HelperApi
{
    readonly IPlatform platform;
    readonly TrustedClients trust;
    readonly string hostName;

    /// <summary>A trusted device used the helper (the tray shows who, and when).</summary>
    public event Action<string>? DeviceServed;

    public HelperApi(IPlatform platform, TrustedClients trust, string hostName)
    {
        this.platform = platform;
        this.trust = trust;
        this.hostName = hostName;
    }

    public async Task<HttpResponse> HandleAsync(HttpRequest request, byte[]? clientCertificateDer, CancellationToken token)
    {
        // Discovery: VibeLight checks the helper is here before offering
        // anything it controls. Says nothing about the PC beyond its name.
        if (request.Path == "/info")
        {
            return request.Method == "GET"
                ? HttpResponse.Json(200, new InfoResponse("VibeLight Helper", Protocol.Version, hostName))
                : HttpResponse.Json(405, new ErrorResponse("Use GET."));
        }

        var device = trust.Authorize(clientCertificateDer);
        if (device is null)
        {
            return HttpResponse.Json(401, new ErrorResponse(
                "This device isn't paired with this PC's streaming host, or isn't allowed to launch apps there."));
        }
        DeviceServed?.Invoke(device.Name);

        switch (request.Method, request.Path)
        {
            case ("GET", "/status"):
                return HttpResponse.Json(200, platform.Status());

            case ("POST", "/match"):
            {
                var match = Read<MatchRequest>(request);
                if (match is null || !GameRules.IsSaneSize(match.Width, match.Height))
                {
                    return HttpResponse.Json(400, new ErrorResponse("Send {\"width\": …, \"height\": …} for a real display size."));
                }
                return HttpResponse.Json(200, platform.Match(match.Width, match.Height));
            }

            case ("POST", "/restore"):
                return HttpResponse.Json(200, platform.Restore());

            case ("POST", "/quit-game"):
            {
                var quit = Read<QuitGameRequest>(request) ?? new QuitGameRequest(null);
                var grace = TimeSpan.FromSeconds(Math.Clamp(quit.GraceSeconds ?? 5, 1, 30));
                return HttpResponse.Json(200, await platform.QuitGameAsync(grace, token));
            }

            case (_, "/status" or "/match" or "/restore" or "/quit-game"):
                return HttpResponse.Json(405, new ErrorResponse("Wrong method for this route."));

            default:
                return HttpResponse.Json(404, new ErrorResponse("No such route."));
        }
    }

    static T? Read<T>(HttpRequest request) where T : class
    {
        if (request.Body.Length == 0) return null;
        try { return JsonSerializer.Deserialize<T>(request.Body, Protocol.Json); }
        catch (JsonException) { return null; }
    }
}
