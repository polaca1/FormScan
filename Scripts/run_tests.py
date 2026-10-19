"""Run XCTest, bounding Xcode's occasional hang after a fully passing suite."""
import argparse
import os
import queue
import re
import signal
import subprocess
import sys
import threading
import time


def run(command, expected, log_path, grace=90):
    process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                               text=True, bufsize=1, start_new_session=True)
    output = queue.Queue()

    def read():
        for line in process.stdout:
            output.put(line)
        output.put(None)

    threading.Thread(target=read, daemon=True).start()
    root_passed = False
    count_passed = False
    completed_at = None
    stream_done = False
    exited_at = None
    with open(log_path, 'w') as log:
        while True:
            try:
                line = output.get(timeout=0.25)
            except queue.Empty:
                line = ''
            if line is None:
                stream_done = True
            elif line:
                print(line, end='', flush=True)
                log.write(line); log.flush()
                if re.search(r"Test Suite '(Selected tests|All tests)' passed", line):
                    root_passed = True
                match = re.search(r'Executed (\d+) tests?, with (\d+) failures?', line)
                if match and int(match[1]) == expected and int(match[2]) == 0 and root_passed:
                    count_passed = True
                if root_passed and count_passed and completed_at is None:
                    completed_at = time.monotonic()
            status = process.poll()
            if status is not None:
                if exited_at is None:
                    exited_at = time.monotonic()
                if stream_done or time.monotonic() - exited_at > 1:
                    if status == 0 and not (root_passed and count_passed):
                        print(f'Expected a passing root suite with exactly {expected} tests.', flush=True)
                        return 1
                    return status
            if status is None and completed_at is not None and time.monotonic() - completed_at > grace:
                message = f'All {expected} XCTest cases passed; xcodebuild stalled while finalizing the result bundle.\n'
                print(message, end='', flush=True); log.write(message); log.flush()
                for sig, timeout in [(signal.SIGINT, 15), (signal.SIGTERM, 10), (signal.SIGKILL, 5)]:
                    try:
                        os.killpg(process.pid, sig)
                        process.wait(timeout=timeout)
                        break
                    except ProcessLookupError:
                        break
                    except subprocess.TimeoutExpired:
                        continue
                # A normal nonzero exit is never converted to success. This path
                # only handles a process still alive after the exact root suite
                # and expected zero-failure test count have both been recorded.
                return 0


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--expected', type=int, required=True)
    parser.add_argument('--log', required=True)
    parser.add_argument('--grace', type=float, default=90)
    parser.add_argument('command', nargs=argparse.REMAINDER)
    args = parser.parse_args()
    command = args.command[1:] if args.command[:1] == ['--'] else args.command
    if not command:
        parser.error('An xcodebuild command is required')
    sys.exit(run(command, args.expected, args.log, args.grace))
