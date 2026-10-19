"""Use an installed iPhone simulator with bounded, visible boot diagnostics."""
import json
import os
import re
import subprocess


def run(arguments, timeout, capture=False):
    print("Running:", " ".join(arguments), flush=True)
    return subprocess.run(arguments, check=True, timeout=timeout, text=True,
                          stdout=subprocess.PIPE if capture else None).stdout


major = os.environ.get("SIMULATOR_OS_MAJOR", "26")
devices = json.loads(run(["xcrun", "simctl", "list", "devices", "available", "-j"], 90, True))["devices"]
choices = [(runtime, device) for runtime, group in devices.items() if "iOS-" + major in runtime
           for device in group if device["name"].startswith("iPhone")]
assert choices, "No installed iPhone with the requested iOS simulator runtime"
latest = max((runtime for runtime, _ in choices), key=lambda value: tuple(int(part) for part in re.findall(r"\d+", value)))
phones = [device for runtime, device in choices if runtime == latest]
phones.sort(key=lambda device: (device["state"] != "Booted", device["name"] != "iPhone 14 Pro",
                                device["name"] != "iPhone 17 Pro", device["name"]))
chosen = phones[0]
identifier = chosen["udid"]
print("Testing installed simulator:", chosen["name"], latest, identifier, flush=True)
try:
    run(["xcrun", "simctl", "bootstatus", identifier, "-b"], 360)
except subprocess.TimeoutExpired:
    run(["xcrun", "simctl", "list", "devices", "available"], 30)
    raise
with open(os.environ["GITHUB_ENV"], "a") as output:
    output.write("SIMULATOR_ID=" + identifier + "\n")
    output.write("SIMULATOR_NAME=" + chosen["name"] + "\n")
