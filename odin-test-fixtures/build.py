#!/usr/bin/env python3
"""Assemble ODIN pipeline test fixtures into dist/<name>/ (and optional .tar.gz).

Each fixture = base agent + the overlay in variants/<name>/.
Fixtures 02 (EICAR) and 03 (fake secrets) are GENERATED here instead of
being committed, so the repo itself never trips GitHub push protection
or local antivirus.

Usage:  python build.py            # build all fixtures into dist/
        python build.py --tar      # also produce dist/<name>.tar.gz
"""
import hashlib
import shutil
import string
import sys
import tarfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent
BASE = ROOT / "base"
VARIANTS = ROOT / "variants"
DIST = ROOT / "dist"

# Standard EICAR antivirus test string, split so this source file is not
# itself detected. It is not malware: every AV vendor recognises it as a test.
EICAR = (
    "X5O!P%@AP[4\\PZX54(P^)7CC)7}$"
    + "EICAR-STANDARD-ANTIVIRUS-TEST-FILE!$H+H*"
)

# Fake credentials matching gitleaks' default rule formats. Values are derived
# from a hash of a fixed seed: high-entropy (so entropy filters don't drop
# them) but invented, not tied to any real account. Generated at build time
# so they never sit in the git history.
def _fake(alphabet: str, length: int, label: str) -> str:
    out, i = "", 0
    while len(out) < length:
        digest = hashlib.sha256(f"odin-test-fixture:{label}:{i}".encode()).digest()
        out += "".join(alphabet[b % len(alphabet)] for b in digest)
        i += 1
    return out[:length]


_UP27 = string.ascii_uppercase + "234567"            # gitleaks aws-access-token
_ALNUM = string.ascii_letters + string.digits
_B64ISH = _ALNUM + "/+"

FAKE_SECRETS = {
    "aws_key": "AKIA" + _fake(_UP27, 16, "aws_key"),
    "aws_secret": _fake(_B64ISH, 40, "aws_secret"),
    "github_pat": "ghp_" + _fake(_ALNUM, 36, "github"),
    "anthropic": "sk-ant-api03-" + _fake(_ALNUM + "_-", 93, "anthropic") + "AA",
}

FIXTURES = [
    "00-clean",
    "01-bad-manifest",
    "02-eicar",
    "03-leaked-secrets",
    "04-risky-code",
    "05-overreach",
    "06-smoke-fail",
]


def write_eicar(dest: Path) -> None:
    (dest / "src" / "assets").mkdir(parents=True, exist_ok=True)
    (dest / "src" / "assets" / "icon.dat").write_text(EICAR)


def write_secrets(dest: Path) -> None:
    s = FAKE_SECRETS
    (dest / "src" / "config.py").write_text(
        '"""Fixture 03 — hardcoded fake credentials (expected: gitleaks hit)."""\n'
        f'AWS_ACCESS_KEY_ID = "{s["aws_key"]}"\n'
        f'AWS_SECRET_ACCESS_KEY = "{s["aws_secret"]}"\n'
        f'GITHUB_TOKEN = "{s["github_pat"]}"\n'
        f'ANTHROPIC_API_KEY = "{s["anthropic"]}"\n'
    )
    (dest / ".env").write_text(
        f'AWS_ACCESS_KEY_ID={s["aws_key"]}\nGITHUB_TOKEN={s["github_pat"]}\n'
    )


def retag_manifest(dest: Path, name: str) -> None:
    """Give generated fixtures a distinct id so they don't collide in the DB.

    The stdlib can read TOML but not write it, so this is a plain text
    replacement on the base manifest's id and image_uri lines.
    """
    path = dest / "manifest.toml"
    slug = name.split("-", 1)[1]
    text = path.read_text()
    text = text.replace('id = "weather-digest-v1"', f'id = "weather-digest-{slug}-v1"')
    text = text.replace("agents/weather-digest:1.0.0", f"agents/weather-digest-{slug}:1.0.0")
    path.write_text(text)


def build(name: str, make_tar: bool) -> Path:
    dest = DIST / name
    if dest.exists():
        shutil.rmtree(dest)
    shutil.copytree(BASE, dest)

    overlay = VARIANTS / name
    if overlay.exists():
        shutil.copytree(overlay, dest, dirs_exist_ok=True)

    if name == "02-eicar":
        write_eicar(dest)
    elif name == "03-leaked-secrets":
        write_secrets(dest)

    if name not in ("00-clean", "01-bad-manifest") and not overlay.joinpath("manifest.toml").exists():
        retag_manifest(dest, name)

    if make_tar:
        with tarfile.open(DIST / f"{name}.tar.gz", "w:gz") as tar:
            tar.add(dest, arcname=name)
    return dest


def main() -> None:
    make_tar = "--tar" in sys.argv
    DIST.mkdir(exist_ok=True)
    for name in FIXTURES:
        print(f"built {build(name, make_tar).relative_to(ROOT)}")


if __name__ == "__main__":
    main()
