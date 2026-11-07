"""Build runtime PNG/ICO assets from the approved logo explorations (Pillow)."""
from pathlib import Path
from PIL import Image


def main():
    root = Path(__file__).resolve().parents[1]
    source = root / "design/logo-explorations/2026-11-08"
    target = root / "assets/logos"
    target.mkdir(parents=True, exist_ok=True)
    for name in ("01-orbit", "02-frames", "03-current", "04-screen"):
        image = Image.open(source / f"{name}.png").convert("RGBA")
        # Use a consistent optical area while retaining transparent safe space.
        image = image.crop(image.getbbox())
        image.thumbnail((448, 448), Image.Resampling.LANCZOS)
        canvas = Image.new("RGBA", (512, 512))
        canvas.alpha_composite(image, ((512-image.width)//2, (512-image.height)//2))
        canvas.save(target / f"{name}.png", optimize=True)
        canvas.save(target / f"{name}.ico", sizes=[(s, s) for s in (16, 20, 24, 32, 48, 64, 128, 256)])
    default = (target / "01-orbit.ico").read_bytes()
    (root / "windows/runner/resources/app_icon.ico").write_bytes(default)
    (root / "assets/tray.ico").write_bytes(default)
    print("Generated four PNG/ICO logo pairs and default Windows/tray icons.")


if __name__ == "__main__":
    main()
