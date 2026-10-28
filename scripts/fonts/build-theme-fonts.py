#!/usr/bin/env python3
"""Builds the theme fonts bundled in VibeLight/Resources/Fonts/.

Every family is OFL 1.1, fetched from the google/fonts repository:

    https://raw.githubusercontent.com/google/fonts/main/ofl/<family>/<file>

Variable fonts become static instances (SwiftUI's Font.custom cannot set
variation axes) and the large Japanese families are cut to Latin, which keeps
the bundle small. IBM Plex Sans Condensed is copied UNMODIFIED: its licence
reserves the name "Plex", so a subset could not keep it.

Instances get their own PostScript names ("FrauncesVL-Black" …) so they never
collide with a copy of the family the user installed on their Mac. The Swift
side addresses fonts by these names (VibeLight/UI/ThemeFonts.swift); keep the
two in step.

Usage:
    pip install fonttools
    python3 scripts/fonts/build-theme-fonts.py <dir with the downloaded sources> VibeLight/Resources/Fonts

The source directory holds one folder per family, named as in google/fonts
(fraunces/, archivo/, ibmplexsanscondensed/, delagothicone/, zenkakugothicnew/),
each with its .ttf files and OFL.txt.
"""
import os
import shutil
import sys

from fontTools import subset
from fontTools.ttLib import TTFont
from fontTools.varLib import instancer

# Latin, Latin-1, Latin Extended-A, general punctuation, € ™ − and the arrows the
# settings rows use. Anything else (a game name in Greek, say) falls back to the
# system font glyph by glyph.
UNICODES = (
    list(range(0x20, 0x7F))
    + list(range(0xA0, 0x180))
    + list(range(0x2010, 0x2028))
    + list(range(0x2030, 0x203B))
    + [0x20AC, 0x2122, 0x2190, 0x2191, 0x2192, 0x2193, 0x2212]
)

# Zen Kaku draws · — ‘ ’ “ ” … at full (Japanese) width, which spaced the chip
# summaries ("1080p · 120 fps") far apart; without them those characters
# fall back to the system font's proportional ones.
FULL_WIDTH_PUNCTUATION = {0xB7} | set(range(0x2010, 0x2028)) | set(range(0x2030, 0x203B))
PROPORTIONAL_PUNCTUATION_ONLY = {"zenkakugothicnew"}

# (source family dir, source file, axes or None, PostScript name, family, style)
INSTANCES = [
    # Night Edition — display serif (hero, masthead, focused caption, folio).
    ("fraunces", "Fraunces[SOFT,WONK,opsz,wght].ttf",
     {"wght": 900, "opsz": 48, "SOFT": 30, "WONK": 0}, "FrauncesVL-Black", "Fraunces VL", "Black"),
    ("fraunces", "Fraunces-Italic[SOFT,WONK,opsz,wght].ttf",
     {"wght": 900, "opsz": 144, "SOFT": 0, "WONK": 1}, "FrauncesVL-BlackItalic", "Fraunces VL", "Black Italic"),
    ("fraunces", "Fraunces-Italic[SOFT,WONK,opsz,wght].ttf",
     {"wght": 700, "opsz": 18, "SOFT": 0, "WONK": 1}, "FrauncesVL-BoldItalic", "Fraunces VL", "Bold Italic"),
    ("fraunces", "Fraunces-Italic[SOFT,WONK,opsz,wght].ttf",
     {"wght": 500, "opsz": 14, "SOFT": 0, "WONK": 0}, "FrauncesVL-MediumItalic", "Fraunces VL", "Medium Italic"),
    # Grid 72 — one family at three widths.
    ("archivo", "Archivo[wdth,wght].ttf", {"wdth": 125, "wght": 900},
     "ArchivoVL-ExpandedBlack", "Archivo VL", "Expanded Black"),
    ("archivo", "Archivo[wdth,wght].ttf", {"wdth": 100, "wght": 500},
     "ArchivoVL-Medium", "Archivo VL", "Medium"),
    ("archivo", "Archivo[wdth,wght].ttf", {"wdth": 100, "wght": 600},
     "ArchivoVL-SemiBold", "Archivo VL", "SemiBold"),
    ("archivo", "Archivo[wdth,wght].ttf", {"wdth": 100, "wght": 700},
     "ArchivoVL-Bold", "Archivo VL", "Bold"),
    ("archivo", "Archivo[wdth,wght].ttf", {"wdth": 100, "wght": 800},
     "ArchivoVL-ExtraBold", "Archivo VL", "ExtraBold"),
    ("archivo", "Archivo[wdth,wght].ttf", {"wdth": 80, "wght": 500},
     "ArchivoVL-NarrowMedium", "Archivo VL", "Narrow Medium"),
    ("archivo", "Archivo[wdth,wght].ttf", {"wdth": 80, "wght": 600},
     "ArchivoVL-NarrowSemiBold", "Archivo VL", "Narrow SemiBold"),
    ("archivo", "Archivo[wdth,wght].ttf", {"wdth": 75, "wght": 700},
     "ArchivoVL-NarrowBold", "Archivo VL", "Narrow Bold"),
    # Kabuki Cut — heavy gothic display, calm gothic for everything small.
    ("delagothicone", "DelaGothicOne-Regular.ttf", None,
     "DelaGothicOneVL-Regular", "Dela Gothic One VL", "Regular"),
    ("zenkakugothicnew", "ZenKakuGothicNew-Medium.ttf", None,
     "ZenKakuGothicNewVL-Medium", "Zen Kaku Gothic New VL", "Medium"),
    ("zenkakugothicnew", "ZenKakuGothicNew-Bold.ttf", None,
     "ZenKakuGothicNewVL-Bold", "Zen Kaku Gothic New VL", "Bold"),
    ("zenkakugothicnew", "ZenKakuGothicNew-Black.ttf", None,
     "ZenKakuGothicNewVL-Black", "Zen Kaku Gothic New VL", "Black"),
]

# Copied byte for byte (Reserved Font Name "Plex").
UNMODIFIED = [
    ("ibmplexsanscondensed", "IBMPlexSansCondensed-Medium.ttf"),
    ("ibmplexsanscondensed", "IBMPlexSansCondensed-SemiBold.ttf"),
    ("ibmplexsanscondensed", "IBMPlexSansCondensed-Bold.ttf"),
]

# Each family's licence, renamed so the flat app bundle has no two OFL.txt.
LICENCES = {
    "fraunces": "Fraunces-OFL.txt",
    "archivo": "Archivo-OFL.txt",
    "ibmplexsanscondensed": "IBMPlexSansCondensed-OFL.txt",
    "delagothicone": "DelaGothicOne-OFL.txt",
    "zenkakugothicnew": "ZenKakuGothicNew-OFL.txt",
}


def rename(font, ps_name, family, style):
    name = font["name"]
    full = f"{family} {style}"
    # Keep only the ids that identify the font; the copyright, licence and
    # designer records (0, 3, 5, 7–14) stay as the authors wrote them.
    for rec in list(name.names):
        if rec.nameID in (1, 2, 4, 6, 16, 17, 21, 22, 25):
            name.removeNames(nameID=rec.nameID)
    # Legacy (id 1/2) names allow only Regular/Italic/Bold/Bold Italic as the
    # style; any other weight joins the family name instead.
    if style in ("Regular", "Italic", "Bold", "Bold Italic"):
        legacy_family, legacy_style = family, style
    elif style.endswith(" Italic"):
        legacy_family, legacy_style = f"{family} {style[:-len(' Italic')]}", "Italic"
    else:
        legacy_family, legacy_style = f"{family} {style}", "Regular"
    name.setName(legacy_family, 1, 3, 1, 0x409)
    name.setName(legacy_style, 2, 3, 1, 0x409)
    name.setName(full, 4, 3, 1, 0x409)
    name.setName(ps_name, 6, 3, 1, 0x409)
    name.setName(family, 16, 3, 1, 0x409)
    name.setName(style, 17, 3, 1, 0x409)
    if "STAT" in font:
        del font["STAT"]   # a static instance no longer needs the style attributes


def cut(font, unicodes):
    opts = subset.Options()
    opts.layout_features = ["*"]
    opts.name_IDs = ["*"]
    opts.name_languages = ["*"]
    opts.notdef_outline = True
    opts.hinting = False          # Apple's rasteriser ignores TrueType hints
    opts.glyph_names = False
    sub = subset.Subsetter(opts)
    sub.populate(unicodes=unicodes)
    sub.subset(font)


def main(src, out):
    os.makedirs(out, exist_ok=True)
    for fam, fname, axes, ps, family, style in INSTANCES:
        font = TTFont(os.path.join(src, fam, fname))
        if axes is not None:
            font = instancer.instantiateVariableFont(font, axes)
        unicodes = UNICODES
        if fam in PROPORTIONAL_PUNCTUATION_ONLY:
            unicodes = [u for u in UNICODES if u not in FULL_WIDTH_PUNCTUATION]
        cut(font, unicodes)
        rename(font, ps, family, style)
        dest = os.path.join(out, ps + ".ttf")
        font.save(dest)
        print(f"{os.path.getsize(dest):>8}  {ps}.ttf")
    for fam, fname in UNMODIFIED:
        dest = os.path.join(out, fname)
        shutil.copyfile(os.path.join(src, fam, fname), dest)
        print(f"{os.path.getsize(dest):>8}  {fname} (unmodified)")
    for fam, lic in LICENCES.items():
        shutil.copyfile(os.path.join(src, fam, "OFL.txt"), os.path.join(out, lic))


if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    main(sys.argv[1], sys.argv[2])
