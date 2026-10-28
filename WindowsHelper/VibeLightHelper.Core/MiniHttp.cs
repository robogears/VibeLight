using System.Text;

namespace VibeLightHelper.Core;

public sealed record HttpRequest(string Method, string Path, IReadOnlyDictionary<string, string> Headers, byte[] Body)
{
    public string? Header(string name) =>
        Headers.TryGetValue(name.ToLowerInvariant(), out var value) ? value : null;
}

public sealed record HttpResponse(int Status, string Body, string ContentType = "application/json")
{
    public static HttpResponse Json<T>(int status, T value) =>
        new(status, System.Text.Json.JsonSerializer.Serialize(value, Protocol.Json));
}

/// <summary>
/// Just enough HTTP/1.1 for one client that sends one small request per
/// connection (VibeLight always closes). Bounded so a stranger on the network
/// can't make the helper buffer without limit.
/// </summary>
public static class MiniHttp
{
    public const int MaxHeaderBytes = 16 * 1024;
    public const int MaxBodyBytes = 64 * 1024;

    public static async Task<HttpRequest?> ReadRequestAsync(Stream stream, CancellationToken token)
    {
        var buffer = new byte[MaxHeaderBytes];
        int filled = 0, headerEnd = -1;
        while (headerEnd < 0)
        {
            if (filled == buffer.Length) return null;   // headers too large
            int read = await stream.ReadAsync(buffer.AsMemory(filled, buffer.Length - filled), token);
            if (read == 0) return null;                  // closed before a full request
            filled += read;
            headerEnd = IndexOf(buffer, filled, "\r\n\r\n"u8);
        }

        var head = Encoding.ASCII.GetString(buffer, 0, headerEnd).Split("\r\n");
        var requestLine = head[0].Split(' ');
        if (requestLine.Length != 3 || !requestLine[2].StartsWith("HTTP/1.", StringComparison.Ordinal)) return null;

        var headers = new Dictionary<string, string>();
        foreach (var line in head.Skip(1))
        {
            int colon = line.IndexOf(':');
            if (colon <= 0) return null;
            headers[line[..colon].Trim().ToLowerInvariant()] = line[(colon + 1)..].Trim();
        }

        int length = 0;
        if (headers.TryGetValue("content-length", out var lengthText)
            && (!int.TryParse(lengthText, out length) || length < 0 || length > MaxBodyBytes))
        {
            return null;
        }

        var body = new byte[length];
        int bodyStart = headerEnd + 4;
        int already = Math.Min(filled - bodyStart, length);
        Array.Copy(buffer, bodyStart, body, 0, already);
        int got = already;
        while (got < length)
        {
            int read = await stream.ReadAsync(body.AsMemory(got, length - got), token);
            if (read == 0) return null;
            got += read;
        }

        // The path without its query string; routes take no query arguments.
        var path = requestLine[1];
        int query = path.IndexOf('?');
        if (query >= 0) path = path[..query];
        return new HttpRequest(requestLine[0].ToUpperInvariant(), path, headers, body);
    }

    public static async Task WriteResponseAsync(Stream stream, HttpResponse response, CancellationToken token)
    {
        var body = Encoding.UTF8.GetBytes(response.Body);
        var head = $"HTTP/1.1 {response.Status} {Reason(response.Status)}\r\n" +
                   $"Content-Type: {response.ContentType}; charset=utf-8\r\n" +
                   $"Content-Length: {body.Length}\r\n" +
                   "Connection: close\r\n\r\n";
        await stream.WriteAsync(Encoding.ASCII.GetBytes(head), token);
        await stream.WriteAsync(body, token);
        await stream.FlushAsync(token);
    }

    static string Reason(int status) => status switch
    {
        200 => "OK",
        400 => "Bad Request",
        401 => "Unauthorized",
        404 => "Not Found",
        405 => "Method Not Allowed",
        409 => "Conflict",
        429 => "Too Many Requests",
        _ => "Error",
    };

    static int IndexOf(byte[] haystack, int length, ReadOnlySpan<byte> needle) =>
        haystack.AsSpan(0, length).IndexOf(needle);
}
