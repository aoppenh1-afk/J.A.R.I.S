#!/usr/bin/env python3
"""Check the generated Sparkle feed against its release archive before publishing."""
import base64
import pathlib
import plistlib
import re
import subprocess
import sys
import tempfile
import urllib.parse
import xml.etree.ElementTree as ET
import zipfile

feed, archive = map(pathlib.Path, sys.argv[1:])
sparkle = "{http://www.andymatuschak.org/xml-namespaces/sparkle}"
root = ET.parse(feed).getroot()
enclosures = root.findall("./channel/item/enclosure")
if len(enclosures) != 1:
    raise SystemExit("Expected exactly one update in this release feed.")
enclosure = enclosures[0]
url = urllib.parse.urlparse(enclosure.attrib.get("url", ""))
if url.scheme != "https" or not url.netloc:
    raise SystemExit("The update must download over HTTPS.")
if pathlib.PurePosixPath(urllib.parse.unquote(url.path)).name != archive.name:
    raise SystemExit("The feed points to a different archive filename.")
if int(enclosure.attrib.get("length", "0")) != archive.stat().st_size:
    raise SystemExit("The feed archive length is incorrect.")
signature = base64.b64decode(enclosure.attrib.get(sparkle + "edSignature", ""), validate=True)
if len(signature) != 64:
    raise SystemExit("The feed is missing a valid Ed25519 archive signature.")
item = root.find("./channel/item")
version = item.findtext(sparkle + "version") or enclosure.attrib.get(sparkle + "version")
if not version:
    raise SystemExit("The feed must contain an update build number.")
with zipfile.ZipFile(archive) as bundle:
    manifests = [name for name in bundle.namelist()
                 if len(name.split("/")) == 3 and name.endswith(".app/Contents/Info.plist")]
    if len(manifests) != 1:
        raise SystemExit("The update archive must contain exactly one top-level app.")
    info = plistlib.loads(bundle.read(manifests[0]))
if version != str(info.get("CFBundleVersion")):
    raise SystemExit("The feed version does not match the app build number.")
feed_bytes = feed.read_bytes()
signed = re.search(rb"<!-- sparkle-signatures:\s*edSignature: ([A-Za-z0-9+/=]+)\s*length: ([0-9]+)\s*-->", feed_bytes)
if not signed or int(signed.group(2)) != signed.start():
    raise SystemExit("The appcast is missing its full-feed signature.")
with tempfile.NamedTemporaryFile(prefix="jarvis-signed-appcast-") as payload:
    payload.write(feed_bytes[:signed.start()])
    payload.flush()
    subprocess.run([
        "swift", str(pathlib.Path(__file__).with_name("verify-update-signatures.swift")),
        info["SUPublicEDKey"], enclosure.attrib[sparkle + "edSignature"], str(archive),
        signed.group(1).decode("ascii"), payload.name,
    ], check=True)
print(f"Validated update feed for build {version}: {archive.name}")
