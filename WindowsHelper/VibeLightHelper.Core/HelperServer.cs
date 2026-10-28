using System.Net;
using System.Net.Security;
using System.Net.Sockets;
using System.Security.Authentication;
using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;

namespace VibeLightHelper.Core;

/// <summary>
/// HTTPS on one port, IPv4 and IPv6, one request per connection. The client
/// presents its GameStream certificate (asked for, not required, so /info works
/// without one); <see cref="TrustedClients"/> decides what it may do.
/// </summary>
public sealed class HelperServer : IDisposable
{
    readonly HelperApi api;
    readonly X509Certificate2 certificate;
    readonly TcpListener listener;
    readonly CancellationTokenSource stopping = new();
    /// A handful at once is plenty for one couch; more is someone misbehaving.
    readonly SemaphoreSlim slots = new(8);

    /// Long enough for the slowest route (Quit Game waits up to 30 s for a
    /// game to close), short enough that a silent connection is dropped.
    static readonly TimeSpan ConnectionTimeout = TimeSpan.FromSeconds(45);

    public HelperServer(HelperApi api, X509Certificate2 certificate, int port)
    {
        this.api = api;
        this.certificate = certificate;
        listener = MakeListener(port);
    }

    /// IPv4 and IPv6 on one socket; plain IPv4 on a PC with IPv6 switched off
    /// (creating the IPv6 socket fails outright there).
    static TcpListener MakeListener(int port)
    {
        try
        {
            var dual = new TcpListener(IPAddress.IPv6Any, port);
            dual.Server.DualMode = true;
            return dual;
        }
        catch (SocketException)
        {
            return new TcpListener(IPAddress.Any, port);
        }
    }

    public int Port => ((IPEndPoint)listener.LocalEndpoint).Port;

    public void Start()
    {
        listener.Start();
        _ = AcceptLoopAsync();
    }

    async Task AcceptLoopAsync()
    {
        while (!stopping.IsCancellationRequested)
        {
            TcpClient client;
            try { client = await listener.AcceptTcpClientAsync(stopping.Token); }
            catch (OperationCanceledException) { return; }
            catch (ObjectDisposedException) { return; }
            catch (SocketException) { continue; }

            if (!await slots.WaitAsync(0))
            {
                client.Dispose();
                continue;
            }
            _ = Task.Run(async () =>
            {
                try { await ServeAsync(client); }
                finally { slots.Release(); }
            });
        }
    }

    async Task ServeAsync(TcpClient client)
    {
        using (client)
        using (var timeout = CancellationTokenSource.CreateLinkedTokenSource(stopping.Token))
        {
            timeout.CancelAfter(ConnectionTimeout);
            try
            {
                // Any certificate is accepted at the TLS layer — they are
                // self-signed by design — and judged by TrustedClients instead.
                using var tls = new SslStream(client.GetStream(), leaveInnerStreamOpen: false,
                                              (_, _, _, _) => true);
                await tls.AuthenticateAsServerAsync(new SslServerAuthenticationOptions
                {
                    ServerCertificate = certificate,
                    ClientCertificateRequired = true,
                    CertificateRevocationCheckMode = X509RevocationMode.NoCheck,
                }, timeout.Token);

                var request = await MiniHttp.ReadRequestAsync(tls, timeout.Token);
                if (request is null) return;
                var clientDer = tls.RemoteCertificate?.GetRawCertData();
                var response = await api.HandleAsync(request, clientDer, timeout.Token);
                await MiniHttp.WriteResponseAsync(tls, response, timeout.Token);
            }
            catch (OperationCanceledException) { }
            catch (IOException) { }
            catch (AuthenticationException) { }
            catch (SocketException) { }
        }
    }

    public void Dispose()
    {
        stopping.Cancel();
        listener.Stop();
        stopping.Dispose();
    }
}

/// <summary>The helper's own TLS certificate: made once, kept beside its
/// settings. Self-signed; VibeLight pins it the first time it connects.</summary>
public static class CertificateStore
{
    public static X509Certificate2 LoadOrCreate(string pfxPath)
    {
        if (File.Exists(pfxPath))
        {
            try { return new X509Certificate2(File.ReadAllBytes(pfxPath), (string?)null, X509KeyStorageFlags.UserKeySet); }
            catch (CryptographicException) { }   // damaged: make a new one (VibeLight asks before trusting it)
        }

        using var rsa = RSA.Create(2048);
        var request = new CertificateRequest("CN=VibeLight Helper", rsa, HashAlgorithmName.SHA256, RSASignaturePadding.Pkcs1);
        request.CertificateExtensions.Add(new X509BasicConstraintsExtension(false, false, 0, false));
        request.CertificateExtensions.Add(new X509KeyUsageExtension(
            X509KeyUsageFlags.DigitalSignature | X509KeyUsageFlags.KeyEncipherment, false));
        request.CertificateExtensions.Add(new X509EnhancedKeyUsageExtension(
            new OidCollection { new Oid("1.3.6.1.5.5.7.3.1") }, false));   // server authentication
        using var created = request.CreateSelfSigned(DateTimeOffset.UtcNow.AddDays(-1), DateTimeOffset.UtcNow.AddYears(20));
        var pfx = created.Export(X509ContentType.Pfx);
        Directory.CreateDirectory(Path.GetDirectoryName(pfxPath)!);
        File.WriteAllBytes(pfxPath, pfx);
        // Re-imported from PFX: SChannel needs a key it can use for the handshake.
        return new X509Certificate2(pfx, (string?)null, X509KeyStorageFlags.UserKeySet);
    }
}
