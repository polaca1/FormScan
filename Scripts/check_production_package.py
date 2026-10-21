"""Verify the actual unsigned distribution package before replacing store feeds."""
import hashlib
import json
import pathlib
import plistlib
import sys
import zipfile

EXPECTED = {
    'model.onnx': 'd7ab44396154af79409c9f8a4fded6c9aa907ae6d283fbe5d2b533d3b7314ec1',
    'nano-compact.onnx': '88e2a21b65a7d481e0c65541be874b07f3fa5fcb50c2bd2d78a615fd82c0a523',
    'ffdetr-mobile-int8.onnx': '83adb3b1b6ed8ebe584c9046725913b541daccd9aee6d7bd18a00bbdebe6e33e',
}

def verify(ipa):
    with zipfile.ZipFile(ipa) as archive:
        roots = [n for n in archive.namelist() if n.count('/') == 2 and n.endswith('.app/Info.plist')]
        assert len(roots) == 1
        prefix = roots[0][:-len('Info.plist')]
        info = plistlib.loads(archive.read(roots[0]))
        assert info['CFBundleIdentifier'] == 'com.polaca1.formscan'
        assert int(info['MinimumOSVersion'].split('.')[0]) >= 26
        assert 'UILaunchScreen' in info
        schemes = [s for item in info.get('CFBundleURLTypes', []) for s in item['CFBundleURLSchemes']]
        assert schemes == ['com.polaca1.formscan'], 'Foreign or missing account callback'
        assert not info.get('NSAppTransportSecurity', {}).get('NSAllowsArbitraryLoads', False)
        config = plistlib.loads(archive.read(prefix + 'AccountConfiguration.plist'))
        expected_config = json.loads(pathlib.Path('Config/AccountConfiguration.json').read_text())
        assert config == {key: expected_config[key] for key in ('origin', 'publicKey')}
        assert config['publicKey'].startswith('sb_publishable_')
        for name, checksum in EXPECTED.items():
            assert hashlib.sha256(archive.read(prefix + name)).hexdigest() == checksum, f'Missing or altered inference resource: {name}'
        privacy = plistlib.loads(archive.read(prefix + 'PrivacyInfo.xcprivacy'))
        assert privacy['NSPrivacyTracking'] is False
        assert archive.read(prefix + 'ThirdPartyNotices.txt')
        assert not any('Tests.xctest/' in n or '/embedded.mobileprovision' in n for n in archive.namelist())
        print(f"Production package verified: {info['CFBundleShortVersionString']} ({info['CFBundleVersion']}), native callback, public account configuration, all offline resources and privacy manifest")

if __name__ == '__main__':
    verify(sys.argv[1])
