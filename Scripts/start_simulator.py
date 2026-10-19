"""Boot the requested iPhone with bounded, visible CoreSimulator diagnostics."""
import json
import os
import pathlib
import re
import subprocess


def run(arguments, timeout, capture=False):
    print("Running:", " ".join(arguments), flush=True)
    return subprocess.run(arguments, check=True, timeout=timeout, text=True,
                          stdout=subprocess.PIPE if capture else None).stdout


developer = run(["xcode-select", "-p"], 15, True).strip()
run(["open", "-a", str(pathlib.Path(developer) / "Applications/Simulator.app")], 20)
devices = json.loads(run(["xcrun", "simctl", "list", "devices", "available", "-j"], 60, True))["devices"]
runtimes = [runtime for runtime in devices if "iOS-26" in runtime]
assert runtimes, "No iOS 26 simulator runtime installed"
runtime = max(runtimes, key=lambda value: tuple(int(part) for part in re.findall(r"\d+", value)))
identifier = run(["xcrun", "simctl", "create", "FormScan iPhone 14 Pro",
                  "com.apple.CoreSimulator.SimDeviceType.iPhone-14-Pro", runtime], 30, True).strip()
print("Testing iPhone 14 Pro with", runtime, identifier, flush=True)
run(["xcrun", "simctl", "boot", identifier], 45)
try:
    run(["xcrun", "simctl", "bootstatus", identifier, "-b"], 180)
except subprocess.TimeoutExpired:
    run(["xcrun", "simctl", "list", "devices", "available"], 30)
    raise
with open(os.environ["GITHUB_ENV"], "a") as output:
    output.write("SIMULATOR_ID=" + identifier + "\n")
