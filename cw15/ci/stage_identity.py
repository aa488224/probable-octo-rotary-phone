#!/usr/bin/env python3
"""Stage the MFi accessory identity from the official release IPA.

The upstream repository intentionally ships without the accessory identity.
`SOURCE-BUILD.md` states that a CarPlay session cannot start without it, and that
the resources may be extracted from the published install package. They are kept
out of git and fetched at build time only.
"""
import io
import pathlib
import urllib.request
import zipfile

URL = "https://github.com/xmz28/CarWithin/releases/download/v1.0.5/CarWithin-1.0.5-unsigned.ipa"
FILES = ["certificate.p7b", "leaf.cer", "private.x963"]

root = pathlib.Path(__file__).resolve().parents[1]
out = root / "App" / "BundledIdentity"
out.mkdir(parents=True, exist_ok=True)

req = urllib.request.Request(URL, headers={"User-Agent": "carwithin-ios15-ci"})
data = urllib.request.urlopen(req, timeout=300).read()
print("ipa bytes:", len(data))

archive = zipfile.ZipFile(io.BytesIO(data))
for name in FILES:
    target = out / name
    payload = archive.read("Payload/TDSCarKit.app/" + name)
    target.write_bytes(payload)
    print("staged", name, len(payload), "bytes")
