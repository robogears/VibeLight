using System.Text.Json;

namespace VibeLightHelper.Core;

/// <summary>The routes. Transport-free (the server hands it a parsed request
/// and the client's certificate), so the whole API is tested without a socket.</summary>
public sealed class HelperApi
{
    readonly IPlatform platform;
    readonly TrustedClients trust;
    readonly string hostName;
    readonly PcStateHandler power;

    /// <summary>A trusted device used the helper (the tray shows who, and when).</summary>
    public event Action<string>? DeviceServed;

    public HelperApi(IPlatform platform, TrustedClients trust, string hostName, PcStateHandler power)
    {
        this.platform = platform;
        this.trust = trust;
        this.hostName = hostName;
        this.power = power;
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
                var quit = Read<QuitGameRequest>(request) ?? new QuitGameRequest(null, null);
                var grace = TimeSpan.FromSeconds(Math.Clamp(quit.GraceSeconds ?? 5, 1, 30));
                return HttpResponse.Json(200, await platform.QuitGameAsync(grace, quit.Pid, token));
            }

            case ("POST", "/restart"):
            {
                // MoonDeckBuddy's rule: a delay of 1–30 s, or it's a bad request.
                var restart = Read<RestartRequest>(request);
                if (restart?.DelaySeconds is not int delay ||
                    delay < PcStateHandler.MinGraceSeconds || delay > PcStateHandler.MaxGraceSeconds)
                {
                    return HttpResponse.Json(400, new ErrorResponse("Send {\"delaySeconds\": 1…30}."));
                }
                return HttpResponse.Json(200, power.Restart(delay));
            }

            case ("POST", "/restart/cancel"):
                return HttpResponse.Json(200, power.Cancel()
                    ? new RestartResponse(true, "Restart cancelled.")
                    : new RestartResponse(false, "No restart to cancel."));

            case (_, "/status" or "/match" or "/restore" or "/quit-game" or "/restart" or "/restart/cancel"):
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
