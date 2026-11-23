"""Generate the four synthetic newspaper pages used by the opt-in #818 replay."""

import argparse
from pathlib import Path
import random
import textwrap

from PIL import Image, ImageDraw, ImageFont


def make_pages(directory: Path) -> None:
    directory.mkdir(parents=True, exist_ok=True)
    font_path = "/System/Library/Fonts/Supplemental/Georgia.ttf"
    body = ImageFont.truetype(font_path, 30)
    headline = ImageFont.truetype(font_path, 62)
    rng = random.Random(818)
    places = ["North Quay", "Cedar Park", "Ferry Lane", "West Wharf", "Old Market",
              "Hill Road", "Larch Square", "East Gate"]
    items = ["lamp posts", "benches", "bicycle racks", "bus shelters", "planters",
             "notice boards", "signposts", "drain covers"]

    for page in range(1, 5):
        sheet = Image.new("RGB", (2030, 2800), "white")
        draw = ImageDraw.Draw(sheet)
        draw.text((80, 60), "The District Record", font=headline, fill="black")
        draw.text((80, 155), f"Synthetic OCR fixture   |   Municipal works survey   |   Page {page} of 4",
                  font=body, fill="black")
        draw.line((80, 220, 1950, 220), fill="black", width=3)
        for column in range(2):
            y = 265
            for block in range(9):
                number = (page - 1) * 18 + column * 9 + block + 1
                origin, destination = rng.sample(places, 2)
                item = rng.choice(items)
                entry = (f"{number:02d}. At {origin}, inspectors counted {rng.randint(12, 95)} {item}. "
                         f"The clerk recorded case DR-{rng.randint(10000, 99999)} and sent a copy to "
                         f"{destination}. The next visit is due in {rng.randint(2, 16)} days. "
                         "Residents can check the revised list at the district office.")
                for line in textwrap.wrap(entry, width=51):
                    draw.text((80 + column * 990, y), line, font=body, fill="black")
                    y += 39
                y += 22
        draw.text((80, 2715), f"End of page {page}", font=body, fill="black")
        sheet.save(directory / f"page-{page}.png", optimize=True)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("directory", type=Path)
    make_pages(parser.parse_args().directory)
