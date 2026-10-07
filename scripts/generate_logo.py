"""Render the flat Harmony blue Tianyi-inspired vector for launcher assets."""
from pathlib import Path
from PIL import Image, ImageDraw


def cubic(a, b, c, d, steps=30):
    for i in range(1, steps + 1):
        t = i / steps
        u = 1 - t
        yield (
            u ** 3 * a[0] + 3 * u * u * t * b[0] + 3 * u * t * t * c[0] + t ** 3 * d[0],
            u ** 3 * a[1] + 3 * u * u * t * b[1] + 3 * u * t * t * c[1] + t ** 3 * d[1],
        )


def path(start, segments):
    points = [start]
    current = start
    for item in segments:
        if len(item) == 2:
            points.append(item)
            current = item
        else:
            p1, p2, p3 = item
            points.extend(cubic(current, p1, p2, p3))
            current = p3
    return [(round(x * 2), round(y * 2)) for x, y in points]


root = Path(__file__).resolve().parents[1]
logo = Image.new("RGBA", (1024, 1024), (0, 0, 0, 0))
draw = ImageDraw.Draw(logo)
blue = (0, 125, 255, 255)
outer = path((431, 148), [
    ((362, 56), (220, 45), (119, 125)),
    ((26, 201), (26, 341), (121, 413)),
    ((208, 479), (349, 449), (433, 355)),
    (369, 334),
    ((304, 399), (211, 412), (151, 367)),
    ((88, 320), (85, 223), (149, 172)),
    ((214, 120), (316, 124), (370, 186)),
])
wing = path((185, 286), [
    ((231, 260), (314, 251), (442, 278)),
    ((359, 281), (285, 323), (247, 363)),
    ((226, 338), (204, 312), (185, 286)),
])
draw.polygon(outer, fill=blue)
draw.polygon(wing, fill=blue)

for scope in (root / "AppScope", root / "entry" / "src" / "main"):
    media = scope / "resources" / "base" / "media"
    logo.save(media / "foreground.png")
    Image.new("RGBA", (1024, 1024), (240, 247, 255, 255)).save(media / "background.png")

logo.resize((512, 512), Image.Resampling.LANCZOS).save(
    root / "entry" / "src" / "main" / "resources" / "base" / "media" / "tianyi_logo.png"
)
start_icon = Image.new("RGBA", (144, 144), (240, 247, 255, 255))
start_icon.alpha_composite(logo.resize((144, 144), Image.Resampling.LANCZOS))
start_icon.save(root / "entry" / "src" / "main" / "resources" / "base" / "media" / "startIcon.png")
