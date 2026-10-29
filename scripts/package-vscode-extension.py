#!/usr/bin/env python3
"""Build the bundled, dependency-free VSIX offline using the standard VSIX layout.

The explicit allowlist keeps requests, settings, SDKs and developer files out of
the extension. No npm install, marketplace publishing or artifact upload occurs.
"""
import argparse
import io
import json
import os
from pathlib import Path
import tempfile
import xml.etree.ElementTree as ET
import zipfile

ROOT = Path(__file__).resolve().parent.parent
SOURCE = ROOT / "extensions" / "runbar-vscode"
FILES = ("package.json", "extension.js", "bridge.js", "README.md")
VSIX_NS = "http://schemas.microsoft.com/developer/vsx-schema/2011"
CONTENT_NS = "http://schemas.openxmlformats.org/package/2006/content-types"


def manifest(package):
    ET.register_namespace("", VSIX_NS)
    root = ET.Element("PackageManifest", Version="2.0.0", xmlns=VSIX_NS)
    metadata = ET.SubElement(root, "Metadata")
    ET.SubElement(metadata, "Identity", Language="en-US", Id=package["name"], Version=package["version"], Publisher=package["publisher"])
    ET.SubElement(metadata, "DisplayName").text = package["displayName"]
    ET.SubElement(metadata, "Description", {"xml:space": "preserve"}).text = package["description"]
    ET.SubElement(metadata, "Tags").text = "flutter,dart,runbar,debugging"
    ET.SubElement(metadata, "Categories").text = ",".join(package["categories"])
    ET.SubElement(metadata, "GalleryFlags").text = "Public"
    properties = ET.SubElement(metadata, "Properties")
    for key, value in {
        "Engine": package["engines"]["vscode"],
        "ExtensionDependencies": ",".join(package["extensionDependencies"]),
        "ExtensionPack": "",
        "ExtensionKind": ",".join(package["extensionKind"]),
        "ExecutesCode": "true",
        "EnableProposedApi": "false",
    }.items():
        ET.SubElement(properties, "Property", Id="Microsoft.VisualStudio.Code." + key, Value=value)
    installation = ET.SubElement(root, "Installation")
    ET.SubElement(installation, "InstallationTarget", Id="Microsoft.VisualStudio.Code")
    ET.SubElement(root, "Dependencies")
    assets = ET.SubElement(root, "Assets")
    ET.SubElement(assets, "Asset", Type="Microsoft.VisualStudio.Code.Manifest", Path="extension/package.json", Addressable="true")
    ET.SubElement(assets, "Asset", Type="Microsoft.VisualStudio.Services.Content.Details", Path="extension/README.md", Addressable="true")
    return ET.tostring(root, encoding="utf-8", xml_declaration=True)


def content_types():
    root = ET.Element("Types", xmlns=CONTENT_NS)
    for extension, content_type in (("json", "application/json"), ("js", "application/javascript"), ("md", "text/markdown"), ("vsixmanifest", "text/xml")):
        ET.SubElement(root, "Default", Extension=extension, ContentType=content_type)
    return ET.tostring(root, encoding="utf-8", xml_declaration=True)


def atomic_write(destination, data):
    with tempfile.NamedTemporaryFile(dir=destination.parent, prefix=".runbar-extension-", delete=False) as stream:
        temporary = Path(stream.name)
        try:
            # These are public distribution resources, not connection secrets.
            # Keep them readable when an App/DMG is opened by another Mac user.
            os.fchmod(stream.fileno(), 0o644)
            stream.write(data)
            stream.flush()
            os.replace(temporary, destination)
        finally:
            temporary.unlink(missing_ok=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=ROOT / "dist" / "vscode-bridge")
    arguments = parser.parse_args()
    package = json.loads((SOURCE / "package.json").read_text())
    if package["publisher"] + "." + package["name"] != "kingxcode.runbar-bridge":
        raise SystemExit("Extension ID must match the native bridge URL handler.")
    content = {"extension.vsixmanifest": manifest(package), "[Content_Types].xml": content_types()}
    for name in FILES:
        file = SOURCE / name
        if file.is_symlink() or not file.is_file():
            raise SystemExit("Missing or unexpected extension source: " + name)
        content["extension/" + name] = file.read_bytes()
    output = io.BytesIO()
    with zipfile.ZipFile(output, "w", compression=zipfile.ZIP_DEFLATED) as archive:
        for name in sorted(content):
            entry = zipfile.ZipInfo(name, date_time=(2020, 1, 1, 0, 0, 0))
            entry.compress_type = zipfile.ZIP_DEFLATED
            entry.external_attr = 0o100644 << 16
            archive.writestr(entry, content[name])
    arguments.output.mkdir(parents=True, exist_ok=True)
    vsix = arguments.output / "runbar-bridge.vsix"
    atomic_write(vsix, output.getvalue())
    metadata = {"id": package["publisher"] + "." + package["name"], "version": package["version"]}
    atomic_write(arguments.output / "metadata.json", (json.dumps(metadata, indent=2) + "\n").encode())
    print("Runbar Bridge " + package["version"] + ": " + str(vsix))


if __name__ == "__main__":
    main()
