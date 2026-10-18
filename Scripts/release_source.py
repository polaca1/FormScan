"""Generate both SideStore feeds from the packaged application's actual Info.plist."""
import argparse
import datetime
import json
import pathlib
import plistlib
import zipfile


def generate(ipa, output):
    with zipfile.ZipFile(ipa) as archive:
        name = next(n for n in archive.namelist() if n.count("/") == 2 and n.endswith(".app/Info.plist"))
        info = plistlib.loads(archive.read(name))
    version = info["CFBundleShortVersionString"]
    build = info["CFBundleVersion"]
    tag = f"v{version}"
    base = f"https://github.com/polaca1/FormScan/releases/download/{tag}"
    details = {
        "version": version,
        "buildVersion": build,
        "date": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "downloadURL": f"{base}/FormScan-{version}.ipa",
        "size": pathlib.Path(ipa).stat().st_size,
        "minOSVersion": info["MinimumOSVersion"],
        "localizedDescription": "Liquid Glass nativo para iOS 26. Nuevo inicio con biblioteca, tutorial con documento de ejemplo, modelos locales descargables y selector recomendado para tu dispositivo. Edición sincronizada con el PDF y nuevo icono minimalista.",
    }
    app = {
        "name": "FormScan", "bundleIdentifier": info["CFBundleIdentifier"],
        "developerName": "FormScan", "subtitle": "Escanea. Completa. Comparte.",
        "localizedDescription": "Escanea documentos, importa PDF o imágenes y detecta campos con IA local. Lo que escribes en el formulario aparece inmediatamente en el documento. Guarda, revisa y exporta un PDF listo para compartir.",
        "iconURL": f"{base}/AppIcon.png", "tintColor": "007AFF",
        "versions": [details],
        "version": version, "versionDate": details["date"], "versionDescription": details["localizedDescription"],
        "downloadURL": details["downloadURL"], "size": details["size"], "minOSVersion": details["minOSVersion"],
        "appPermissions": {"entitlements": [], "privacy": {"NSCameraUsageDescription": info["NSCameraUsageDescription"]}},
    }
    output.mkdir(parents=True, exist_ok=True)
    for filename, identifier in [("source.json", "com.polaca1.formscan.source"), ("sidestore-v2.json", "com.polaca1.formscan.source.v2")]:
        source = {"name": "FormScan", "identifier": identifier,
                  "subtitle": "Tus formularios, resueltos.",
                  "description": "Escáner y formularios con IA local. Diseñado para iOS 26.",
                  "iconURL": app["iconURL"], "apps": [app]}
        (output / filename).write_text(json.dumps(source, ensure_ascii=False, indent=2) + "\n")
    assert app["version"] == app["versions"][0]["version"] == info["CFBundleShortVersionString"]
    print(f"Verified IPA and feeds: {version} ({build}), iOS {info['MinimumOSVersion']}, {details['size']} bytes")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("ipa", type=pathlib.Path)
    parser.add_argument("--output", type=pathlib.Path, default=pathlib.Path("release"))
    args = parser.parse_args()
    generate(args.ipa, args.output)
