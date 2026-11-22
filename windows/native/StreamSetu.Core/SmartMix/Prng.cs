using System.Text;

namespace StreamSetu.Core.SmartMix;

/// <summary>FNV-1a 64 over UTF-8 bytes and SplitMix64: integer-only, so every platform draws the same picks. All arithmetic is unsigned 64-bit and wraps.</summary>
public static class Fnv
{
    public static ulong Hash64(ReadOnlySpan<byte> data)
    {
        ulong h = 0xcbf29ce484222325UL;
        foreach (var b in data) { h ^= b; unchecked { h *= 0x100000001b3UL; } }
        return h;
    }

    public static ulong Hash64(string s) => Hash64(Encoding.UTF8.GetBytes(s));
}

public sealed class SplitMix64
{
    private ulong _state;
    public SplitMix64(ulong seed) { _state = seed; }

    public ulong Next()
    {
        unchecked
        {
            _state += 0x9E3779B97F4A7C15UL;
            var z = _state;
            z = (z ^ (z >> 30)) * 0xBF58476D1CE4E5B9UL;
            z = (z ^ (z >> 27)) * 0x94D049BB133111EBUL;
            return z ^ (z >> 31);
        }
    }

    /// <summary>A value in 0..n-1 without modulo bias (values below (2^64 mod n) are redrawn).</summary>
    public ulong Uniform(ulong n)
    {
        if (n == 0) return 0;
        ulong limit = unchecked(0UL - n) % n;
        while (true)
        {
            var x = Next();
            if (x >= limit) return x % n;
        }
    }
}

/// <summary>Strings compare by their UTF-8 bytes, which is the order of their code points (not of UTF-16 units).</summary>
public static class Utf8Order
{
    public static int Compare(string a, string b)
    {
        int i = 0, j = 0;
        while (i < a.Length && j < b.Length)
        {
            var x = CodePoint(a, ref i); var y = CodePoint(b, ref j);
            if (x != y) return x < y ? -1 : 1;
        }
        if (i < a.Length) return 1;
        if (j < b.Length) return -1;
        return 0;
    }

    private static int CodePoint(string s, ref int i)
    {
        var c = s[i];
        if (char.IsHighSurrogate(c) && i + 1 < s.Length && char.IsLowSurrogate(s[i + 1])) { var cp = char.ConvertToUtf32(c, s[i + 1]); i += 2; return cp; }
        i++;
        return c;
    }
}
