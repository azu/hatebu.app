#!/usr/bin/env python3
"""Package the native app and a standalone Alfred workflow from the same CLI build."""
from pathlib import Path
import argparse
import plistlib
import re
import shutil
import zipfile

root = Path(__file__).resolve().parent.parent
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--bin-dir", type=Path, default=root / ".build/release")
parser.add_argument("--tag", help="Require this release tag to match VERSION")
parser.add_argument("--check-version", action="store_true")
args = parser.parse_args()
version = (root / "VERSION").read_text().strip()
if not re.fullmatch(r"(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)", version):
    parser.error("VERSION must contain a numeric version such as 0.1.1")
if args.tag is not None and args.tag != f"v{version}":
    parser.error(f"Release tag {args.tag!r} does not match VERSION ({version})")
if args.check_version:
    print(version)
    raise SystemExit(0)

dist = root / "dist"
app = dist / "HatebuSearch.app" / "Contents"
macos = app / "MacOS"
resources = app / "Resources"
workflow = dist / "workflow"
for directory in [macos, resources, workflow]:
    directory.mkdir(parents=True, exist_ok=True)

def replace_copy(source, destination):
    # Keep the inode of an already running app intact while publishing a rebuild.
    staged = destination.with_name(destination.name + ".new")
    shutil.copy2(source, staged)
    staged.replace(destination)

for binary in ["HatebuSearch", "hatebu"]:
    replace_copy(args.bin_dir / binary, macos / binary)
replace_copy(args.bin_dir / "hatebu", workflow / "hatebu")
info = {
    "CFBundleExecutable": "HatebuSearch",
    "CFBundleIdentifier": "info.azu.hatebusearch",
    "CFBundleName": "Hatebu Search",
    "CFBundleDisplayName": "Hatebu Search",
    "CFBundlePackageType": "APPL",
    "CFBundleShortVersionString": version,
    "CFBundleVersion": version,
    "LSMinimumSystemVersion": "14.0",
    "LSApplicationCategoryType": "public.app-category.productivity",
    "NSHighResolutionCapable": True,
    "NSPrincipalClass": "NSApplication",
    "CFBundleURLTypes": [{"CFBundleURLName": "info.azu.hatebusearch.search", "CFBundleURLSchemes": ["hatebusearch"]}],
}
with (app / "Info.plist").open("wb") as f:
    plistlib.dump(info, f)
with (root / "Alfred/info.plist").open("rb") as f:
    workflow_info = plistlib.load(f)
workflow_info["version"] = version
with (workflow / "info.plist").open("wb") as f:
    plistlib.dump(workflow_info, f)
archive = dist / "HatebuSearch.alfredworkflow"
with zipfile.ZipFile(archive, "w", zipfile.ZIP_DEFLATED) as z:
    for file in [workflow / "hatebu", workflow / "info.plist"]:
        z.write(file, file.name)
shutil.copy2(archive, resources / archive.name)
