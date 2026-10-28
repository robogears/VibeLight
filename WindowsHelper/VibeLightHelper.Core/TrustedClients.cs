using System.Security.Cryptography;
using System.Text.Json;

namespace VibeLightHelper.Core;

/// <summary>
/// Who may use the helper: exactly the devices this PC's streaming host
/// (Vibepollo / Apollo / Sunshine) has paired, with permission to launch apps.
/// A device presents its GameStream client certificate in the TLS handshake —
/// the same certificate the host paired — so a device that can stream from
/// this PC needs no second pairing (owner: "it should just work"), and nobody
/// else on the network gets in. The host keeps paired certificates in
/// <c>sunshine_state.json</c> (<c>root.named_devices[].cert</c>, plus the
/// legacy <c>root.devices[].certs[]</c>), which its installer leaves readable
/// to normal users; only its <c>credentials</c> folder is locked down.
/// </summary>
public sealed class TrustedClients
{
    /// Vibepollo/Apollo <c>PERM::launch</c> (<c>_action &lt;&lt; 2</c> = 1 &lt;&lt; 26).
    /// Plain Sunshine has no permissions, so no <c>perm</c> field means allowed.
    public const uint LaunchPermission = 1u << 26;

    public sealed record PairedDevice(string Name, byte[] CertificateDer, uint? Permissions)
    {
        public bool MayControl => Permissions is not uint perm || (perm & LaunchPermission) != 0;
    }

    readonly Func<IEnumerable<string>> candidatePaths;
    readonly object gate = new();
    List<PairedDevice> devices = new();
    readonly Dictionary<string, DateTime> seen = new();

    public TrustedClients(Func<IEnumerable<string>> candidatePaths)
    {
        this.candidatePaths = candidatePaths;
    }

    /// <summary>The paired device presenting this certificate, if it may use the helper.</summary>
    public PairedDevice? Authorize(byte[]? certificateDer)
    {
        if (certificateDer is null || certificateDer.Length == 0) return null;
        Refresh();
        lock (gate)
        {
            return devices.FirstOrDefault(d => d.MayControl &&
                CryptographicOperations.FixedTimeEquals(d.CertificateDer, certificateDer));
        }
    }

    /// <summary>How many paired devices may use the helper (re-reads the host's list).</summary>
    public int AllowedCount
    {
        get
        {
            Refresh();
            lock (gate) { return devices.Count(d => d.MayControl); }
        }
    }

    /// <summary>Where the paired list was found (for the tray tooltip); empty if nowhere.</summary>
    public IReadOnlyCollection<string> Sources
    {
        get { lock (gate) { return seen.Keys.ToList(); } }
    }

    /// Re-reads the state files when they change (a device paired a minute ago
    /// works straight away).
    void Refresh()
    {
        var found = new List<(string path, DateTime stamp)>();
        foreach (var path in candidatePaths())
        {
            try
            {
                if (File.Exists(path)) found.Add((path, File.GetLastWriteTimeUtc(path)));
            }
            catch (IOException) { }
            catch (UnauthorizedAccessException) { }
        }

        lock (gate)
        {
            bool changed = found.Count != seen.Count ||
                found.Any(f => !seen.TryGetValue(f.path, out var stamp) || stamp != f.stamp);
            if (!changed) return;

            var all = new List<PairedDevice>();
            seen.Clear();
            foreach (var (path, stamp) in found)
            {
                try
                {
                    all.AddRange(Parse(File.ReadAllText(path)));
                    seen[path] = stamp;
                }
                catch (IOException) { }
                catch (UnauthorizedAccessException) { }
                catch (JsonException) { }
            }
            devices = all;
        }
    }

    /// <summary>The paired devices in one state file. Pure, so it is tested.</summary>
    public static List<PairedDevice> Parse(string json)
    {
        var result = new List<PairedDevice>();
        using var doc = JsonDocument.Parse(json);
        if (!doc.RootElement.TryGetProperty("root", out var root) || root.ValueKind != JsonValueKind.Object)
        {
            return result;
        }

        if (root.TryGetProperty("named_devices", out var named) && named.ValueKind == JsonValueKind.Array)
        {
            foreach (var device in named.EnumerateArray())
            {
                if (device.ValueKind != JsonValueKind.Object) continue;
                var der = device.TryGetProperty("cert", out var cert) && cert.ValueKind == JsonValueKind.String
                    ? PemToDer(cert.GetString()!) : null;
                if (der is null) continue;
                var name = device.TryGetProperty("name", out var n) && n.ValueKind == JsonValueKind.String
                    ? n.GetString()! : "";
                uint? perm = device.TryGetProperty("perm", out var p) && p.ValueKind == JsonValueKind.Number
                    && p.TryGetUInt32(out var value) ? value : null;
                result.Add(new PairedDevice(name, der, perm));
            }
        }

        // Legacy layout (older Sunshine): certificates with no names or permissions.
        if (root.TryGetProperty("devices", out var legacy) && legacy.ValueKind == JsonValueKind.Array)
        {
            foreach (var device in legacy.EnumerateArray())
            {
                if (device.ValueKind != JsonValueKind.Object ||
                    !device.TryGetProperty("certs", out var certs) || certs.ValueKind != JsonValueKind.Array) continue;
                foreach (var cert in certs.EnumerateArray())
                {
                    if (cert.ValueKind != JsonValueKind.String) continue;
                    if (PemToDer(cert.GetString()!) is { } der) result.Add(new PairedDevice("", der, null));
                }
            }
        }
        return result;
    }

    public static byte[]? PemToDer(string pem)
    {
        const string begin = "-----BEGIN CERTIFICATE-----", end = "-----END CERTIFICATE-----";
        int start = pem.IndexOf(begin, StringComparison.Ordinal);
        int stop = pem.IndexOf(end, StringComparison.Ordinal);
        if (start < 0 || stop <= start) return null;
        var body = pem[(start + begin.Length)..stop]
            .Replace("\r", "").Replace("\n", "").Replace(" ", "");
        try { return Convert.FromBase64String(body); }
        catch (FormatException) { return null; }
    }

    /// <summary>Where the Sunshine family keeps its state on Windows: the
    /// install folder's <c>config</c> directory (Vibepollo also writes a
    /// <c>vibeshine_state.json</c> beside it).</summary>
    public static IEnumerable<string> DefaultCandidatePaths(string programFiles)
    {
        foreach (var product in new[] { "Vibepollo", "Apollo", "Sunshine" })
        {
            var config = Path.Combine(programFiles, product, "config");
            yield return Path.Combine(config, "sunshine_state.json");
            yield return Path.Combine(config, "vibeshine_state.json");
        }
    }
}
