"""Render actual-size and nearest-neighbour inspection strips. Requires Pillow/rsvg-convert."""
from pathlib import Path
import subprocess
from PIL import Image, ImageDraw

root = Path(__file__).resolve().parent
sizes = (16, 32, 64)
strip = Image.new('RGB', (360, 192))
draw = ImageDraw.Draw(strip)
for row, (background, ink) in enumerate((('#f3f3f5', '#242630'), ('#191b20', '#ededf3'))):
    draw.rectangle((0, row * 96, 360, (row + 1) * 96), fill=background)
    for column, size in enumerate(sizes):
        master = root / ('PasDisk-small.svg' if size <= 32 else 'PasDisk.svg')
        path = root / f'PasDisk-preview-{size}.png'
        subprocess.run(['rsvg-convert', '-w', str(size), '-h', str(size), str(master), '-o', str(path)], check=True)
        with Image.open(path) as icon:
            strip.paste(icon, (column * 120 + (120 - size) // 2, row * 96 + (72 - size) // 2), icon)
        draw.text((column * 120 + 44, row * 96 + 77), f'{size} px', fill=ink)
strip.save(root / 'PasDisk-preview-strip.png')
strip.resize((1440, 768), Image.Resampling.NEAREST).save(root / 'PasDisk-preview-strip-4x.png')

# Retina small sizes use the same optical master at double the pixel dimensions.
packaging = root.parent.parent / 'packaging'
for size in (16, 32, 128, 256, 512):
    for scale in (1, 2):
        suffix = '@2x' if scale == 2 else ''
        with Image.open(packaging / 'PasDisk.iconset' / f'icon_{size}x{size}{suffix}.png') as image:
            assert image.size == (size * scale, size * scale)
            assert image.mode == 'RGBA'
            assert image.getpixel((0, 0))[3] == 0
with Image.open(root / 'PasDisk.png') as image:
    assert image.size == (1024, 1024)
print('Verified 1024 master and all 10 iconset dimensions/transparent margins.')
