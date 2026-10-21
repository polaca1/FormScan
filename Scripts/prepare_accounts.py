"""Build the public client configuration. Never accepts a secret/service-role key."""
import json
import pathlib
import plistlib
import urllib.error
import urllib.request
from urllib.parse import urlsplit


def prepare():
    config = json.loads(pathlib.Path('Config/AccountConfiguration.json').read_text())
    origin, key = config['origin'], config['publicKey']
    parsed = urlsplit(origin)
    assert parsed.scheme == 'https' and parsed.hostname and not parsed.username and not parsed.password
    assert parsed.path in ('', '/') and not parsed.query and not parsed.fragment
    assert key.startswith('sb_publishable_'), 'Only a public publishable key is allowed in the app'
    target = pathlib.Path('Sources/Resources/AccountConfiguration.plist')
    target.write_bytes(plistlib.dumps({'origin': origin, 'publicKey': key}))
    print('Prepared public account configuration; no administrative credentials included')


def readiness():
    config = json.loads(pathlib.Path('Config/AccountConfiguration.json').read_text())
    req = urllib.request.Request(config['origin'] + '/auth/v1/settings', headers={'apikey': config['publicKey']})
    with urllib.request.urlopen(req, timeout=30) as response:
        settings = json.load(response)
    assert settings.get('external', {}).get('email'), 'Enable the email provider before publishing'
    assert settings.get('external', {}).get('google'), 'Enable the Google provider before publishing'
    assert not settings.get('mailer_autoconfirm', True), 'Enable email confirmation before publishing'
    assert not settings.get('disable_signup'), 'Account creation is disabled'
    print('Public account providers and email confirmation are enabled')
    request = urllib.request.Request(config['origin'] + '/rest/v1/rpc/formscan_cloud_health',
                                     data=b'{}', headers={'apikey': config['publicKey'], 'Content-Type': 'application/json'})
    with urllib.request.urlopen(request, timeout=30) as response:
        health = json.load(response)
    assert health.get('schemaVersion') == 1 and health.get('privateBucket') is True, 'Run Backend/001_document_cloud.sql before publishing'
    print('Document storage schema is ready and its bucket is private')


if __name__ == '__main__':
    import argparse
    parser = argparse.ArgumentParser()
    parser.add_argument('--check-service', action='store_true')
    args = parser.parse_args()
    prepare()
    if args.check_service:
        readiness()
