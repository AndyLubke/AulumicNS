<#
  AulumicNS - ShrinkPng.ps1

  Makes the PNG files of a folder smaller (the help screenshots, which are
  built into the exe). GDI+ writes PNG without row filters and with a fast
  deflate; this writes them again:
    - every row with the PNG filter that suits it best (None / Sub / Up /
      Average / Paeth, the smallest sum of absolute differences), then the
      strongest deflate of .NET: lossless;
    - an image with at most 256 colours as a palette PNG: lossless;
    - with -Colors N (2..256) every other image too, reduced to N colours
      (median cut, weighted by how often a colour occurs; then each pixel the
      nearest palette colour, with Floyd-Steinberg dithering when -Dither):
      lossy - the flat UI parts keep their exact colours mostly, gradients
      and covers lose a little.
  A file is only replaced when the new one is smaller.

  Usage:  & .\Tools\ShrinkPng.ps1 -Folder help\shots [-Colors 256] [-Dither]
  Prints the sizes before / after.
#>
param(
  [Parameter(Mandatory = $true)][string]$Folder,
  [int]$Colors = 0,
  [switch]$Dither
)

$ErrorActionPreference = 'Stop'

if (-not ('AulumicNSTools.PngShrink' -as [type])) {
  Add-Type -Language CSharp -ReferencedAssemblies System.Drawing -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Imaging;
using System.IO;
using System.IO.Compression;
using System.Runtime.InteropServices;

namespace AulumicNSTools {
  public static class PngShrink {
    static uint[] crcTable;

    static uint Crc(byte[] type, byte[] data) {
      if (crcTable == null) {
        crcTable = new uint[256];
        for (uint n = 0; n < 256; n++) {
          uint c = n;
          for (int k = 0; k < 8; k++) c = (c & 1) != 0 ? 0xEDB88320u ^ (c >> 1) : c >> 1;
          crcTable[n] = c;
        }
      }
      uint crc = 0xFFFFFFFFu;
      foreach (byte b in type) crc = crcTable[(crc ^ b) & 0xFF] ^ (crc >> 8);
      foreach (byte b in data) crc = crcTable[(crc ^ b) & 0xFF] ^ (crc >> 8);
      return crc ^ 0xFFFFFFFFu;
    }

    static void Chunk(Stream s, string type, byte[] data) {
      byte[] t = System.Text.Encoding.ASCII.GetBytes(type);
      WriteBE(s, (uint)data.Length);
      s.Write(t, 0, 4);
      s.Write(data, 0, data.Length);
      WriteBE(s, Crc(t, data));
    }

    static void WriteBE(Stream s, uint v) {
      s.WriteByte((byte)(v >> 24)); s.WriteByte((byte)(v >> 16));
      s.WriteByte((byte)(v >> 8)); s.WriteByte((byte)v);
    }

    static byte[] Zlib(byte[] raw) {
      var ms = new MemoryStream();
      ms.WriteByte(0x78); ms.WriteByte(0xDA);
      using (var d = new DeflateStream(ms, CompressionLevel.Optimal, true)) d.Write(raw, 0, raw.Length);
      uint a = 1, b = 0;
      foreach (byte x in raw) { a = (a + x) % 65521; b = (b + a) % 65521; }
      WriteBE(ms, (b << 16) | a);
      return ms.ToArray();
    }

    static int Paeth(int a, int b, int c) {
      int p = a + b - c, pa = Math.Abs(p - a), pb = Math.Abs(p - b), pc = Math.Abs(p - c);
      if (pa <= pb && pa <= pc) return a;
      return pb <= pc ? b : c;
    }

    // rows of bpp bytes per pixel; adaptive filter per row (or none)
    static byte[] Filter(byte[] img, int w, int h, int bpp, bool adaptive) {
      int stride = w * bpp;
      var outp = new byte[(stride + 1) * h];
      var cand = new byte[5][];
      for (int f = 0; f < 5; f++) cand[f] = new byte[stride];
      for (int y = 0; y < h; y++) {
        int row = y * stride, prev = row - stride;
        int best = 0;
        if (adaptive) {
          long bestSum = long.MaxValue;
          for (int f = 0; f < 5; f++) {
            long sum = 0;
            byte[] c = cand[f];
            for (int i = 0; i < stride; i++) {
              int x = img[row + i];
              int a = i >= bpp ? img[row + i - bpp] : 0;
              int b = y > 0 ? img[prev + i] : 0;
              int cc = (i >= bpp && y > 0) ? img[prev + i - bpp] : 0;
              int v;
              switch (f) {
                case 0: v = x; break;
                case 1: v = x - a; break;
                case 2: v = x - b; break;
                case 3: v = x - ((a + b) >> 1); break;
                default: v = x - Paeth(a, b, cc); break;
              }
              c[i] = (byte)v;
              sbyte sv = (sbyte)(byte)v;
              sum += Math.Abs((int)sv);
            }
            if (sum < bestSum) { bestSum = sum; best = f; }
          }
          outp[y * (stride + 1)] = (byte)best;
          Buffer.BlockCopy(cand[best], 0, outp, y * (stride + 1) + 1, stride);
        } else {
          outp[y * (stride + 1)] = 0;
          Buffer.BlockCopy(img, row, outp, y * (stride + 1) + 1, stride);
        }
      }
      return outp;
    }

    static byte[] Ihdr(int w, int h, int colorType) {
      var d = new byte[13];
      d[0] = (byte)(w >> 24); d[1] = (byte)(w >> 16); d[2] = (byte)(w >> 8); d[3] = (byte)w;
      d[4] = (byte)(h >> 24); d[5] = (byte)(h >> 16); d[6] = (byte)(h >> 8); d[7] = (byte)h;
      d[8] = 8; d[9] = (byte)colorType;
      return d;
    }

    static byte[] Write(int w, int h, int colorType, byte[] pixels, int bpp, int[] palette) {
      var s = new MemoryStream();
      s.Write(new byte[] { 137, 80, 78, 71, 13, 10, 26, 10 }, 0, 8);
      Chunk(s, "IHDR", Ihdr(w, h, colorType));
      if (palette != null) {
        var pl = new byte[palette.Length * 3];
        for (int i = 0; i < palette.Length; i++) {
          pl[i * 3] = (byte)(palette[i] >> 16); pl[i * 3 + 1] = (byte)(palette[i] >> 8); pl[i * 3 + 2] = (byte)palette[i];
        }
        Chunk(s, "PLTE", pl);
      }
      Chunk(s, "IDAT", Zlib(Filter(pixels, w, h, bpp, palette == null)));
      Chunk(s, "IEND", new byte[0]);
      return s.ToArray();
    }

    // median cut: boxes of (colour, count), split the box with the widest
    // channel at the weighted median until there are n of them
    class Box { public List<KeyValuePair<int, int>> C; }

    static int[] MedianCut(Dictionary<int, int> hist, int n) {
      var boxes = new List<Box> { new Box { C = new List<KeyValuePair<int, int>>(hist) } };
      while (boxes.Count < n) {
        Box split = null; int bestRange = -1, ch = 0;
        foreach (var bx in boxes) {
          if (bx.C.Count < 2) continue;
          for (int k = 0; k < 3; k++) {
            int lo = 255, hi = 0, sh = 16 - 8 * k;
            foreach (var kv in bx.C) { int v = (kv.Key >> sh) & 255; if (v < lo) lo = v; if (v > hi) hi = v; }
            long weight = 0; foreach (var kv in bx.C) weight += kv.Value;
            // the range weighted by how many pixels the box holds (so big boxes split first)
            int score = (int)Math.Min(int.MaxValue, (long)(hi - lo) * (long)Math.Sqrt(weight));
            if (score > bestRange) { bestRange = score; split = bx; ch = k; }
          }
        }
        if (split == null || bestRange <= 0) break;
        int shf = 16 - 8 * ch;
        split.C.Sort((p, q) => ((p.Key >> shf) & 255).CompareTo((q.Key >> shf) & 255));
        long total = 0; foreach (var kv in split.C) total += kv.Value;
        long acc = 0; int cut = 1;
        for (int i = 0; i < split.C.Count - 1; i++) { acc += split.C[i].Value; if (acc * 2 >= total) { cut = i + 1; break; } cut = i + 1; }
        var b2 = new Box { C = split.C.GetRange(cut, split.C.Count - cut) };
        split.C = split.C.GetRange(0, cut);
        boxes.Add(b2);
      }
      var pal = new int[boxes.Count];
      for (int i = 0; i < boxes.Count; i++) {
        long r = 0, g = 0, b = 0, wsum = 0;
        foreach (var kv in boxes[i].C) {
          r += (long)((kv.Key >> 16) & 255) * kv.Value; g += (long)((kv.Key >> 8) & 255) * kv.Value;
          b += (long)(kv.Key & 255) * kv.Value; wsum += kv.Value;
        }
        if (wsum == 0) wsum = 1;
        pal[i] = (int)((r / wsum) << 16 | (g / wsum) << 8 | (b / wsum));
      }
      return pal;
    }

    static int Nearest(int[] pal, int r, int g, int b) {
      int best = 0, bd = int.MaxValue;
      for (int i = 0; i < pal.Length; i++) {
        int dr = ((pal[i] >> 16) & 255) - r, dg = ((pal[i] >> 8) & 255) - g, db = (pal[i] & 255) - b;
        int d = 2 * dr * dr + 4 * dg * dg + 3 * db * db;
        if (d < bd) { bd = d; best = i; if (d == 0) break; }
      }
      return best;
    }

    // returns the new size (or the old one when not smaller)
    public static long Shrink(string path, int colors, bool dither) {
      byte[] orig = File.ReadAllBytes(path);
      int w, h; int[] argb;
      using (var ms = new MemoryStream(orig))
      using (var bmp = new Bitmap(ms)) {
        w = bmp.Width; h = bmp.Height;
        var data = bmp.LockBits(new Rectangle(0, 0, w, h), ImageLockMode.ReadOnly, PixelFormat.Format32bppArgb);
        argb = new int[w * h];
        for (int y = 0; y < h; y++) Marshal.Copy(data.Scan0 + y * data.Stride, argb, y * w, w);
        bmp.UnlockBits(data);
      }
      bool opaque = true;
      var hist = new Dictionary<int, int>();
      foreach (int p in argb) {
        if (((p >> 24) & 255) != 255) opaque = false;
        int c = p & 0xFFFFFF;
        int cnt; hist.TryGetValue(c, out cnt); hist[c] = cnt + 1;
      }
      byte[] best = null;
      if (opaque && hist.Count <= 256) {
        // palette, lossless
        var pal = new int[hist.Count]; var idx = new Dictionary<int, int>();
        int i = 0; foreach (var kv in hist) { pal[i] = kv.Key; idx[kv.Key] = i; i++; }
        var px = new byte[w * h];
        for (int k = 0; k < argb.Length; k++) px[k] = (byte)idx[argb[k] & 0xFFFFFF];
        best = Write(w, h, 3, px, 1, pal);
      } else if (opaque && colors >= 2) {
        int[] pal = MedianCut(hist, Math.Min(colors, 256));
        var px = new byte[w * h];
        var cache = new Dictionary<int, byte>();
        if (!dither) {
          for (int k = 0; k < argb.Length; k++) {
            int c = argb[k] & 0xFFFFFF; byte v;
            if (!cache.TryGetValue(c, out v)) { v = (byte)Nearest(pal, (c >> 16) & 255, (c >> 8) & 255, c & 255); cache[c] = v; }
            px[k] = v;
          }
        } else {
          var er = new int[w + 2]; var eg = new int[w + 2]; var eb = new int[w + 2];
          var nr = new int[w + 2]; var ng = new int[w + 2]; var nb = new int[w + 2];
          for (int y = 0; y < h; y++) {
            Array.Clear(nr, 0, nr.Length); Array.Clear(ng, 0, ng.Length); Array.Clear(nb, 0, nb.Length);
            for (int x = 0; x < w; x++) {
              int c = argb[y * w + x];
              int r = Math.Max(0, Math.Min(255, ((c >> 16) & 255) + er[x + 1] / 16));
              int g = Math.Max(0, Math.Min(255, ((c >> 8) & 255) + eg[x + 1] / 16));
              int b = Math.Max(0, Math.Min(255, (c & 255) + eb[x + 1] / 16));
              int key = (r << 16) | (g << 8) | b; byte v;
              if (!cache.TryGetValue(key, out v)) { v = (byte)Nearest(pal, r, g, b); cache[key] = v; }
              px[y * w + x] = v;
              int qr = r - ((pal[v] >> 16) & 255), qg = g - ((pal[v] >> 8) & 255), qb = b - (pal[v] & 255);
              er[x + 2] += qr * 7; eg[x + 2] += qg * 7; eb[x + 2] += qb * 7;
              nr[x] += qr * 3; ng[x] += qg * 3; nb[x] += qb * 3;
              nr[x + 1] += qr * 5; ng[x + 1] += qg * 5; nb[x + 1] += qb * 5;
              nr[x + 2] += qr; ng[x + 2] += qg; nb[x + 2] += qb;
            }
            var t = er; er = nr; nr = t; t = eg; eg = ng; ng = t; t = eb; eb = nb; nb = t;
          }
        }
        best = Write(w, h, 3, px, 1, pal);
      } else {
        // lossless RGB / RGBA
        int bpp = opaque ? 3 : 4;
        var px = new byte[w * h * bpp];
        for (int k = 0; k < argb.Length; k++) {
          int p = argb[k];
          px[k * bpp] = (byte)(p >> 16); px[k * bpp + 1] = (byte)(p >> 8); px[k * bpp + 2] = (byte)p;
          if (bpp == 4) px[k * bpp + 3] = (byte)(p >> 24);
        }
        best = Write(w, h, opaque ? 2 : 6, px, bpp, null);
      }
      if (best.Length < orig.Length) { File.WriteAllBytes(path, best); return best.Length; }
      return orig.Length;
    }
  }
}
'@
}

$files = Get-ChildItem -LiteralPath $Folder -Filter *.png
$before = 0; $after = 0
foreach ($f in $files) {
  $b = $f.Length
  $a = [AulumicNSTools.PngShrink]::Shrink($f.FullName, $Colors, [bool]$Dither)
  $before += $b; $after += $a
  '{0,-32} {1,7:N0} KB -> {2,7:N0} KB' -f $f.Name, ($b / 1KB), ($a / 1KB)
}
'{0} files: {1:N2} MB -> {2:N2} MB' -f $files.Count, ($before / 1MB), ($after / 1MB)
