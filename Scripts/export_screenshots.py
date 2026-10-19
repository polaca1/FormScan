"""Export genuine XCTest screenshots, including an interrupted result finalizer."""
import argparse
import json
import pathlib
import re
import subprocess
import zstandard

PNG = b'\x89PNG\r\n\x1a\n'
ZSTD = b'\x28\xb5\x2f\xfd'


def decode(path):
    data = path.read_bytes()
    if data.startswith(ZSTD):
        data = zstandard.ZstdDecompressor().decompress(data, max_output_size=128 * 1024 * 1024)
    return data


def recover(bundle, output):
    root = bundle / 'Data'
    found = {}
    for path in sorted(root.glob('data.*')):
        try:
            data = decode(path)
        except zstandard.ZstdError:
            continue
        if data.startswith(PNG):
            continue
        text = data.decode('utf8', errors='replace')
        for match in re.finditer(r'K4:name\[S\d+:StringK2:_vV\d+:(\d\d-[a-z-]+)', text):
            reference = re.search(r'K2:_vV90:(0~[A-Za-z0-9_=-]+)', text[match.end():match.end() + 500])
            if not reference:
                continue
            payload = root / ('data.' + reference[1])
            if payload.exists():
                image = decode(payload)
                if image.startswith(PNG):
                    name = match[1] + '.png'
                    (output / name).write_bytes(image)
                    found[name] = {'suggestedHumanReadableName': match[1] + '_recovered', 'exportedFileName': name}
    if found:
        (output / 'manifest.json').write_text(json.dumps([{'attachments': list(found.values())}], indent=2))
    print(f'Recovered {len(found)} original XCTest screenshots from {bundle}')
    return len(found)


def export(bundle, output, recovery_only=False):
    output.mkdir(parents=True, exist_ok=True)
    if not recovery_only:
        try:
            subprocess.run(['xcrun', 'xcresulttool', 'export', 'attachments', '--path', str(bundle), '--output-path', str(output)], timeout=90, check=True)
            if (output / 'manifest.json').exists():
                return
        except (FileNotFoundError, subprocess.TimeoutExpired, subprocess.CalledProcessError) as error:
            print('Using stored XCTest payloads because the result bundle was not finalized:', error)
    recover(bundle, output)


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('bundle', type=pathlib.Path)
    parser.add_argument('output', type=pathlib.Path)
    parser.add_argument('--recover', action='store_true')
    args = parser.parse_args()
    export(args.bundle, args.output, args.recover)
