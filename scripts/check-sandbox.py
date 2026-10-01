"""Verify the production sandbox's preference IPC and isolation without an API call."""
from pathlib import Path
import os
import subprocess
import tempfile

root = Path(__file__).resolve().parent.parent
source = (root / "Sources/AIReviewerWatcher/main.swift").read_text()

def function(name, next_name):
    return source[source.index("func " + name + "("):source.index("func " + next_name + "(")]

with tempfile.TemporaryDirectory(prefix="ai-reviewer-sandbox-") as temporary:
    directory = Path(temporary).resolve()
    swift = directory / "profile.swift"
    swift.write_text("import Foundation\n" + function("sandboxString", "copyCodexAuthMaterial")
                     + function("sandboxProfile", "codexFailureMessage")
                     + function("sanitizedCodexLogTail", "runCodexExecution") + """
let directory = URL(fileURLWithPath: CommandLine.arguments[1])
let log = directory.appendingPathComponent("startup.log")
try "Error: Failed to synchronize managed preferences (code -32600)".write(to: log, atomically: true, encoding: .utf8)
precondition(sanitizedCodexLogTail(logURL: log) == "Codex could not synchronize macOS managed preferences during startup.")
try "Unknown error with sensitive content".write(to: log, atomically: true, encoding: .utf8)
precondition(sanitizedCodexLogTail(logURL: log) == nil)
print(sandboxProfile(bundleURL: directory, runURL: directory,
                    authHomeURL: directory, outputURL: directory,
                    logURL: directory))
""")
    generator = directory / "profile"
    subprocess.run(["swiftc", str(swift), "-o", str(generator)], check=True)
    profile = directory / "sandbox.sb"
    profile.write_text(subprocess.check_output([str(generator), str(directory)], text=True))
    native = directory / "shm.c"
    native.write_text("""
#include <fcntl.h>
#include <sys/mman.h>
#include <unistd.h>
#include <string.h>
int main(int argc, char **argv) {
    if (argc != 3) return 2;
    if (!strcmp(argv[1], "delete")) return shm_unlink(argv[2]) < 0;
    int flags = !strcmp(argv[1], "create") ? O_CREAT | O_EXCL | O_RDWR :
                !strcmp(argv[1], "write") ? O_RDWR : O_RDONLY;
    int fd = shm_open(argv[2], flags, 0600);
    if (fd < 0) return 1;
    close(fd);
    return 0;
}
""")
    helper = directory / "shm"
    subprocess.run(["clang", str(native), "-o", str(helper)], check=True)
    names = [f"/cfprefs_test_{os.getpid()}", f"/other_test_{os.getpid()}"]
    created = []
    try:
        for name in names:
            subprocess.run([str(helper), "create", name], check=True)
            created.append(name)
        def probe(action, name):
            return subprocess.run(["/usr/bin/sandbox-exec", "-f", str(profile),
                                   str(helper), action, name], capture_output=True).returncode
        assert probe("read", names[0]) == 0, "CFPreferences IPC read must work"
        assert probe("write", names[0]) != 0, "CFPreferences IPC write must remain denied"
        assert probe("read", names[1]) != 0, "Unrelated IPC must remain denied"
        result = subprocess.run(["/usr/bin/sandbox-exec", "-f", str(profile),
                                 "/bin/cat", str(root / "README.md")], capture_output=True)
        assert result.returncode != 0, "Live repository must remain unreadable"
    finally:
        for name in created:
            subprocess.run([str(helper), "delete", name], check=True)

print("Sandbox checks passed (preferences IPC read, denied IPC write, unrelated IPC, live repository).")
