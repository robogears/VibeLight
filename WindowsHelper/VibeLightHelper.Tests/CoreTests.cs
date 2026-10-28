using System.Net.Security;
using System.Net.Sockets;
using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
using System.Text;
using System.Text.Json;
using VibeLightHelper.Core;
using Xunit;

namespace VibeLightHelper.Tests;

public class MiniHttpTests
{
    static Task<HttpRequest?> Parse(string raw) =>
        MiniHttp.ReadRequestAsync(new MemoryStream(Encoding.ASCII.GetBytes(raw)), CancellationToken.None);

    [Fact]
    public async Task ReadsMethodPathHeadersAndBody()
    {
        var request = await Parse("POST /match?x=1 HTTP/1.1\r\nHost: pc\r\nContent-Length: 13\r\n" +
                                  "X-Device: iPad\r\n\r\n{\"width\":640}");
        Assert.NotNull(request);
        Assert.Equal("POST", request!.Method);
        Assert.Equal("/match", request.Path);
        Assert.Equal("iPad", request.Header("X-Device"));
        Assert.Equal("{\"width\":640}", Encoding.UTF8.GetString(request.Body));
    }

    [Fact]
    public async Task RefusesOversizeAndMalformedRequests()
    {
        Assert.Null(await Parse($"POST /x HTTP/1.1\r\nContent-Length: {MiniHttp.MaxBodyBytes + 1}\r\n\r\n"));
        Assert.Null(await Parse("GET /x HTTP/1.1\r\n" + new string('a', MiniHttp.MaxHeaderBytes) + "\r\n\r\n"));
        Assert.Null(await Parse("nonsense\r\n\r\n"));
        Assert.Null(await Parse("POST /x HTTP/1.1\r\nContent-Length: 10\r\n\r\nshort"));
    }
}

public class TrustedClientsTests
{
    [Fact]
    public void ReadsNamedAndLegacyDevicesWithPermissions()
    {
        var (_, pem) = NewCertificate("A");
        var (_, legacyPem) = NewCertificate("B");
        var json = JsonSerializer.Serialize(new
        {
            root = new
            {
                named_devices = new object[]
                {
                    new { name = "William's iPad", cert = pem, perm = TrustedClients.LaunchPermission | 1u },
                    new { name = "View only", cert = pem, perm = 1u << 25 },
                },
                devices = new[] { new { certs = new[] { legacyPem } } },
            },
        });
        var devices = TrustedClients.Parse(json);
        Assert.Equal(3, devices.Count);
        Assert.True(devices[0].MayControl);
        Assert.False(devices[1].MayControl);                  // may view, may not launch
        Assert.True(devices[2].MayControl);                   // legacy: no permissions = allowed
    }

    [Fact]
    public void AuthorizesOnlyPairedCertificatesAndSeesNewPairings()
    {
        var path = Path.Combine(Path.GetTempPath(), $"vlh-{Guid.NewGuid():N}.json");
        try
        {
            var (paired, pem) = NewCertificate("paired");
            var (stranger, strangerPem) = NewCertificate("stranger");
            File.WriteAllText(path, StateJson(pem));
            var trust = new TrustedClients(() => new[] { path });
            Assert.NotNull(trust.Authorize(paired.RawData));
            Assert.Null(trust.Authorize(stranger.RawData));
            Assert.Null(trust.Authorize(null));

            // Paired on the host a moment ago: works without restarting the helper.
            File.WriteAllText(path, StateJson(pem, strangerPem));
            File.SetLastWriteTimeUtc(path, DateTime.UtcNow.AddSeconds(5));
            Assert.NotNull(trust.Authorize(stranger.RawData));
        }
        finally { File.Delete(path); }
    }

    [Fact]
    public void LooksInTheSunshineFamilyConfigFolders()
    {
        var paths = TrustedClients.DefaultCandidatePaths(@"C:\Program Files").ToList();
        Assert.Contains(Path.Combine(@"C:\Program Files", "Vibepollo", "config", "sunshine_state.json"), paths);
        Assert.Contains(Path.Combine(@"C:\Program Files", "Sunshine", "config", "sunshine_state.json"), paths);
    }

    internal static string StateJson(params string[] pems) => JsonSerializer.Serialize(new
    {
        root = new { named_devices = pems.Select((p, i) => new { name = $"Device {i}", cert = p, perm = uint.MaxValue }) },
    });

    internal static (X509Certificate2 Certificate, string Pem) NewCertificate(string name)
    {
        using var rsa = RSA.Create(2048);
        var request = new CertificateRequest($"CN={name}", rsa, HashAlgorithmName.SHA256, RSASignaturePadding.Pkcs1);
        var cert = request.CreateSelfSigned(DateTimeOffset.UtcNow.AddDays(-1), DateTimeOffset.UtcNow.AddYears(1));
        var withKey = new X509Certificate2(cert.Export(X509ContentType.Pfx));
        return (withKey, cert.ExportCertificatePem());
    }
}

public class GameRulesTests
{
    [Fact]
    public void NeverTreatsTheShellLaunchersOrHostAsTheGame()
    {
        Assert.False(GameRules.MayBeGame("explorer"));
        Assert.False(GameRules.MayBeGame("steamwebhelper"));   // Steam Big Picture
        Assert.False(GameRules.MayBeGame("Vibepollo"));
        Assert.False(GameRules.MayBeGame(""));
        Assert.True(GameRules.MayBeGame("eldenring"));
    }

    [Fact]
    public void KeepsTheRefreshRate()
    {
        var modes = new[] { (1920, 1080, 60), (1920, 1080, 120), (1920, 1080, 144), (3840, 2160, 60) };
        Assert.Equal((1920, 1080, 120), GameRules.PickMode(modes, 1920, 1080, 120));
        Assert.Equal((1920, 1080, 144), GameRules.PickMode(modes, 1920, 1080, 165));   // fastest not above
        Assert.Equal((3840, 2160, 60), GameRules.PickMode(modes, 3840, 2160, 120));
        Assert.Null(GameRules.PickMode(modes, 2560, 1440, 60));
    }

    [Fact]
    public void AGameFillsMostOfItsDisplay()
    {
        Assert.True(GameRules.CoversDisplay(1920, 1080, 1920, 1080));
        Assert.True(GameRules.CoversDisplay(1280, 720, 1920, 1080));
        Assert.False(GameRules.CoversDisplay(400, 300, 1920, 1080));
        Assert.False(GameRules.IsSaneSize(100000, 1080));
    }
}

public class IconFileTests
{
    static byte[] Ico(params int[] widths)
    {
        var bytes = new List<byte> { 0, 0, 1, 0, (byte)widths.Length, 0 };
        int offset = 6 + 16 * widths.Length;
        foreach (var width in widths)
        {
            bytes.AddRange(new byte[] { (byte)(width == 256 ? 0 : width), (byte)(width == 256 ? 0 : width), 0, 0, 1, 0, 32, 0 });
            bytes.AddRange(BitConverter.GetBytes(4));       // image length
            bytes.AddRange(BitConverter.GetBytes(offset));
            offset += 4;
        }
        foreach (var width in widths) bytes.AddRange(new byte[] { (byte)width, 0, 0, 0 });
        return bytes.ToArray();
    }

    [Fact]
    public void PicksTheSmallestImageAtLeastTheTraySize()
    {
        var ico = Ico(16, 32, 24, 256);
        Assert.Equal(16, IconFile.Pick(ico, 16)?.Size);
        Assert.Equal(24, IconFile.Pick(ico, 20)?.Size);    // 125% scaling: 20 px
        Assert.Equal(256, IconFile.Pick(ico, 200)?.Size);
        Assert.Equal(32, IconFile.Pick(Ico(16, 32), 48)?.Size);   // none big enough: the biggest
        var picked = IconFile.Pick(ico, 32)!.Value;
        Assert.Equal(32, ico[picked.Offset]);
    }

    [Fact]
    public void RefusesWhatIsNotAnIcon()
    {
        Assert.Null(IconFile.Pick(new byte[] { 1, 2, 3 }, 16));
        Assert.Null(IconFile.Pick(System.Text.Encoding.ASCII.GetBytes("\u0089PNG...."), 16));
    }
}

public class HelperApiTests
{
    sealed class FakePlatform : IPlatform
    {
        public (int, int)? Matched;
        public TimeSpan? Grace;
        public StatusResponse Status() => new(new DisplayInfo(@"\\.\DISPLAY1", 1920, 1080, 120), null, Matched != null);
        public MatchResponse Match(int width, int height)
        {
            Matched = (width, height);
            return new MatchResponse(true, new DisplayInfo(@"\\.\DISPLAY1", width, height, 120), null, false, "ok");
        }
        public MatchResponse Restore() => new(true, null, null, false, "restored");
        public Task<QuitGameResponse> QuitGameAsync(TimeSpan grace, CancellationToken token)
        {
            Grace = grace;
            return Task.FromResult(new QuitGameResponse(true, "Game", false, "closed"));
        }
    }

    readonly FakePlatform platform = new();
    readonly X509Certificate2 paired;
    readonly HelperApi api;

    public HelperApiTests()
    {
        var (cert, pem) = TrustedClientsTests.NewCertificate("ipad");
        paired = cert;
        var path = Path.Combine(Path.GetTempPath(), $"vlh-{Guid.NewGuid():N}.json");
        File.WriteAllText(path, TrustedClientsTests.StateJson(pem));
        api = new HelperApi(platform, new TrustedClients(() => new[] { path }), "Gaming PC");
    }

    Task<HttpResponse> Send(string method, string path, string body = "", byte[]? cert = null) =>
        api.HandleAsync(new HttpRequest(method, path, new Dictionary<string, string>(), Encoding.UTF8.GetBytes(body)),
                        cert, CancellationToken.None);

    [Fact]
    public async Task InfoNeedsNoCertificate()
    {
        var response = await Send("GET", "/info");
        Assert.Equal(200, response.Status);
        Assert.Contains("Gaming PC", response.Body);
    }

    [Fact]
    public async Task EverythingElseNeedsAPairedDevice()
    {
        Assert.Equal(401, (await Send("GET", "/status")).Status);
        Assert.Equal(401, (await Send("POST", "/quit-game", "{}", TrustedClientsTests.NewCertificate("x").Certificate.RawData)).Status);
        Assert.Equal(200, (await Send("GET", "/status", cert: paired.RawData)).Status);
    }

    [Fact]
    public async Task MatchTakesARealSize()
    {
        Assert.Equal(400, (await Send("POST", "/match", "{\"width\":5,\"height\":5}", paired.RawData)).Status);
        Assert.Equal(200, (await Send("POST", "/match", "{\"width\":1920,\"height\":1080}", paired.RawData)).Status);
        Assert.Equal((1920, 1080), platform.Matched);
    }

    [Fact]
    public async Task QuitGameGraceIsBounded()
    {
        await Send("POST", "/quit-game", "{\"graceSeconds\":600}", paired.RawData);
        Assert.Equal(TimeSpan.FromSeconds(30), platform.Grace);
        await Send("POST", "/quit-game", "", paired.RawData);
        Assert.Equal(TimeSpan.FromSeconds(5), platform.Grace);
    }

    [Fact]
    public async Task UnknownRoutesAndMethods()
    {
        Assert.Equal(404, (await Send("GET", "/nope", cert: paired.RawData)).Status);
        Assert.Equal(405, (await Send("GET", "/match", cert: paired.RawData)).Status);
    }
}

/// Real TLS on loopback: the device's certificate travels in the handshake.
public class HelperServerTests
{
    [Fact]
    public async Task APairedDeviceIsServedOverTlsAndAStrangerIsNot()
    {
        var (device, pem) = TrustedClientsTests.NewCertificate("ipad");
        var statePath = Path.Combine(Path.GetTempPath(), $"vlh-{Guid.NewGuid():N}.json");
        var pfxPath = Path.Combine(Path.GetTempPath(), $"vlh-{Guid.NewGuid():N}", "helper.pfx");
        File.WriteAllText(statePath, TrustedClientsTests.StateJson(pem));
        var api = new HelperApi(new NullPlatform(), new TrustedClients(() => new[] { statePath }), "PC");
        using var server = new HelperServer(api, CertificateStore.LoadOrCreate(pfxPath), port: 0);
        server.Start();

        Assert.StartsWith("HTTP/1.1 200", await Get(server.Port, "/status", device));
        Assert.StartsWith("HTTP/1.1 401", await Get(server.Port, "/status", null));
        Assert.StartsWith("HTTP/1.1 200", await Get(server.Port, "/info", null));
        // The certificate persists: the same one comes back (VibeLight pins it).
        Assert.Equal(CertificateStore.LoadOrCreate(pfxPath).Thumbprint, CertificateStore.LoadOrCreate(pfxPath).Thumbprint);
    }

    static async Task<string> Get(int port, string path, X509Certificate2? clientCert)
    {
        using var tcp = new TcpClient();
        await tcp.ConnectAsync("127.0.0.1", port);
        using var tls = new SslStream(tcp.GetStream(), false, (_, _, _, _) => true);
        await tls.AuthenticateAsClientAsync(new SslClientAuthenticationOptions
        {
            TargetHost = "helper",
            ClientCertificates = clientCert is null ? null : new X509CertificateCollection { clientCert },
            LocalCertificateSelectionCallback = clientCert is null ? null : (_, _, _, _, _) => clientCert,
        });
        await tls.WriteAsync(Encoding.ASCII.GetBytes($"GET {path} HTTP/1.1\r\nHost: helper\r\nConnection: close\r\n\r\n"));
        using var reader = new StreamReader(tls);
        return await reader.ReadToEndAsync();
    }

    sealed class NullPlatform : IPlatform
    {
        public StatusResponse Status() => new(null, null, false);
        public MatchResponse Match(int width, int height) => new(false, null, null, false, "");
        public MatchResponse Restore() => new(false, null, null, false, "");
        public Task<QuitGameResponse> QuitGameAsync(TimeSpan grace, CancellationToken token) =>
            Task.FromResult(new QuitGameResponse(false, null, false, ""));
    }
}
