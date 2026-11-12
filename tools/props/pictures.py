"""pictures.py -- the pictures baked onto the racks: the engraved maker's plates and the armory's stencil.

    python tools/props/pictures.py        (system Python with Pillow; Blender's Python has no Pillow)

Writes tools/props/textures/pictures/<paint>.png, which looks.py maps onto the plate faces (models.py Kit.plate gives
each its region). The RED channel is the mark: white where the plate is engraved (or the stencil painted), black where
it is bare metal (or bare paint); looks.py lays the cut colour and a little relief from it. Every name on them is made
up.
"""
import os

from PIL import Image, ImageDraw, ImageFilter, ImageFont

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, 'textures', 'pictures')
FONTS = 'C:/Windows/Fonts'

# paint: (plate width, height in metres, lines [(text, font file, size as a fraction of the height, centre y 0..1)],
#         border)
PLATES = {
    'plate_oak': (0.144, 0.022, [('SAN ANDREAS ARMORY CO.', 'ENGR.TTF', 0.42, 0.42),
                                 ('LOS SANTOS  \u00b7  EST. 1921', 'cambria.ttc', 0.22, 0.78)], True),
    'plate_walnut': (0.134, 0.018, [('VINEWOOD HUNT CLUB', 'ENGR.TTF', 0.50, 0.44),
                                    ('MEMBERS\u2019 RACK', 'cambria.ttc', 0.24, 0.80)], True),
    'plate_pistols': (0.214, 0.022, [('PRIVATE COLLECTION', 'ENGR.TTF', 0.46, 0.45),
                                     ('HANDGUNS  \u00b7  1911 \u2013 PRESENT', 'cambria.ttc', 0.22, 0.80)], True),
    'plate_heritage': (0.194, 0.029, [('LOS SANTOS RIFLE ASSOCIATION', 'ENGR.TTF', 0.26, 0.32),
                                      ('STATE CHAMPIONSHIP', 'georgiai.ttf', 0.20, 0.56),
                                      ('PALETO BAY  \u00b7  1958', 'cambria.ttc', 0.15, 0.76)], True),
    'plate_stand': (0.096, 0.0065, [('SECURE-STOW  5', 'bahnschrift.ttf', 0.62, 0.52)], False),
    'stencil_armory': (0.24, 0.07, [('ARMS ROOM', 'STENCIL.TTF', 0.46, 0.33),
                                    ('RACK 02 - 12 PLACES', 'STENCIL.TTF', 0.26, 0.78)], False),
}
WIDTH = 2048


def draw(paint, w_m, h_m, lines, border):
    W = WIDTH
    H = max(64, int(round(W * h_m / w_m)))
    ink = Image.new('L', (W, H), 0)
    d = ImageDraw.Draw(ink)
    if border:
        m = int(H * 0.08)
        d.rounded_rectangle((m, m, W - m, H - m), radius=int(H * 0.10), outline=255, width=max(2, int(H * 0.025)))
    for text, font, size, cy in lines:
        f = ImageFont.truetype(os.path.join(FONTS, font), max(8, int(H * size)))
        # shrink to fit the width if a line is too long
        while d.textlength(text, font=f) > W * 0.90 and f.size > 8:
            f = ImageFont.truetype(os.path.join(FONTS, font), f.size - 2)
        d.text((W / 2, H * cy), text, font=f, fill=255, anchor='mm')
    ink = ink.filter(ImageFilter.GaussianBlur(0.6))
    img = Image.merge('RGB', (ink, ink, ink))
    os.makedirs(OUT, exist_ok=True)
    path = os.path.join(OUT, paint + '.png')
    img.save(path)
    return path, (W, H)


def main():
    for paint, (w, h, lines, border) in PLATES.items():
        path, size = draw(paint, w, h, lines, border)
        print(paint, size, path)


if __name__ == '__main__':
    main()
