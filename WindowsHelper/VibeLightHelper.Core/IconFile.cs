namespace VibeLightHelper.Core;

/// <summary>
/// Picks one image out of a .ico file. Windows makes an icon from a single
/// image's bytes (<c>CreateIconFromResourceEx</c>), not from the file, so the
/// tray takes the image nearest the size Windows draws by the clock.
/// </summary>
public static class IconFile
{
    /// <summary>Where the best image for <paramref name="size"/> pixels sits in
    /// the file: the smallest one at least that big, else the biggest. Null
    /// when the bytes aren't an icon file.</summary>
    public static (int Offset, int Length, int Size)? Pick(byte[] ico, int size)
    {
        if (ico.Length < 6 || ReadUInt16(ico, 0) != 0 || ReadUInt16(ico, 2) != 1) return null;
        int count = ReadUInt16(ico, 4);
        (int Offset, int Length, int Size)? best = null;
        for (int i = 0; i < count; i++)
        {
            int entry = 6 + 16 * i;
            if (entry + 16 > ico.Length) return null;
            int width = ico[entry] == 0 ? 256 : ico[entry];
            int length = (int)ReadUInt32(ico, entry + 8);
            int offset = (int)ReadUInt32(ico, entry + 12);
            if (length <= 0 || offset < 0 || (long)offset + length > ico.Length) continue;

            bool better = best is not { } current
                || (width >= size && (current.Size < size || width < current.Size))
                || (current.Size < size && width > current.Size);
            if (better) best = (offset, length, width);
        }
        return best;
    }

    static int ReadUInt16(byte[] bytes, int at) => bytes[at] | bytes[at + 1] << 8;

    static uint ReadUInt32(byte[] bytes, int at) =>
        (uint)(bytes[at] | bytes[at + 1] << 8 | bytes[at + 2] << 16 | bytes[at + 3] << 24);
}
