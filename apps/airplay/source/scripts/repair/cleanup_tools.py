#!/usr/bin/env python3
"""Relocate only identified development bundles from the historical prototype.

The app in /Applications, libplist's installed prefix, sources, preferences and
Launchpad database are never changed. Unknown bundles are reported and kept.
"""
import argparse
import datetime
import hashlib
import json
import os
from pathlib import Path
import plistlib
import pwd
import re
import stat
import subprocess
import sys
import tempfile
import uuid

APP_ID = "local.chevy.airplay"
CMAKE_ID = "org.cmake.cmake"
CMAKE_VERSION = "3.31.12"
CMAKE_DIST = "cmake-3.31.12-macos-universal"
LSREGISTER = Path("/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister")


def require(condition, message):
    if not condition:
        raise ValueError(message)


def is_within(path, parent):
    try:
        Path(path).relative_to(parent)
        return True
    except ValueError:
        return False


def hash_file(path):
    digest = hashlib.sha256()
    with Path(path).open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def safe_owned_path(path, home, uid, existing=True):
    """Check ancestors lexically, without following user-created symlinks."""
    path = Path(os.path.abspath(str(path)))
    require(is_within(path, home) and path != home, "Path is outside the current user's home: " + str(path))
    require(not any(ord(c) < 32 for c in str(path)), "Control characters in a filesystem path are not supported.")
    current = home
    for part in path.relative_to(home).parts:
        current = current / part
        if not os.path.lexists(str(current)):
            require(not existing, "The path does not exist: " + str(current))
            continue
        info = current.lstat()
        require(not stat.S_ISLNK(info.st_mode), "A path component is a symbolic link: " + str(current))
        require(info.st_uid == uid, "A path component belongs to another user: " + str(current))
    return path


def read_bundle(bundle, home, uid):
    bundle = safe_owned_path(bundle, home, uid)
    require(bundle.is_dir(), "The bundle is not a directory.")
    info_path = safe_owned_path(bundle / "Contents/Info.plist", home, uid)
    require(info_path.is_file(), "The bundle Info.plist is not a regular file.")
    with info_path.open("rb") as stream:
        info = plistlib.load(stream)
    require(isinstance(info, dict), "The bundle Info.plist is not a dictionary.")
    result = {"path": str(bundle), "id": info.get("CFBundleIdentifier"),
              "name": info.get("CFBundleDisplayName", info.get("CFBundleName")),
              "executable": info.get("CFBundleExecutable"),
              "version": info.get("CFBundleShortVersionString"),
              "build": info.get("CFBundleVersion")}
    # Only these public scalar values are included in a report.
    for key in ("id", "name", "executable", "version", "build"):
        if result[key] is not None and not isinstance(result[key], str):
            result[key] = "(unexpected value type)"
    return result


def outer_bundles(root):
    for directory, folders, _files in os.walk(str(root), topdown=True, followlinks=False):
        folders.sort()
        descend = []
        for name in folders:
            path = Path(directory) / name
            if path.is_symlink():
                continue
            if name.lower().endswith(".app"):
                yield path
            else:
                descend.append(name)
        folders[:] = descend


def classify(bundle, prototype, home, uid):
    record = {"path": str(bundle), "classification": "keep_unknown"}
    try:
        require(is_within(bundle, prototype) and bundle != prototype,
                "The bundle is outside the historical prototype; it is kept.")
        record.update(read_bundle(bundle, home, uid))
        expected_cmake = prototype / "herramientas" / CMAKE_DIST / "CMake.app"
        if bundle == expected_cmake and record["id"] == CMAKE_ID and \
                record["executable"] == "CMake" and record["version"] == CMAKE_VERSION:
            gui = safe_owned_path(bundle / "Contents/MacOS/CMake", home, uid)
            cli = safe_owned_path(bundle / "Contents/bin/cmake", home, uid)
            require(gui.is_file() and os.access(str(gui), os.X_OK), "CMake's GUI executable is missing.")
            require(cli.is_file() and os.access(str(cli), os.X_OK), "CMake's CLI executable is missing.")
            record["classification"] = "move_cmake_distribution"
            record["source"] = str(expected_cmake.parent)
            record["executable_relative"] = "CMake.app/Contents/bin/cmake"
            record["executable_sha256"] = hash_file(cli)
        elif record["id"] == APP_ID and record["executable"] == "uxplay":
            marker = safe_owned_path(bundle / "Contents/Resources/installation.txt", home, uid)
            require(marker.is_file(), "The AirPlay installation marker is not a regular file.")
            with marker.open("r", encoding="utf-8") as stream:
                lines = [stream.readline().rstrip("\r\n"), stream.readline().rstrip("\r\n")]
            require(lines == [APP_ID, "1"], "The AirPlay marker does not identify schema 1.")
            executable = safe_owned_path(bundle / "Contents/MacOS/uxplay", home, uid)
            require(executable.is_file() and os.access(str(executable), os.X_OK), "The AirPlay test executable is missing.")
            record["classification"] = "archive_owned_airplay"
            record["source"] = str(bundle)
            record["executable_relative"] = "Contents/MacOS/uxplay"
            record["executable_sha256"] = hash_file(executable)
        if record["classification"] != "keep_unknown":
            source = safe_owned_path(record["source"], home, uid)
            info = source.lstat()
            record["source_identity"] = {"device": info.st_dev, "inode": info.st_ino, "uid": info.st_uid}
            record["info_sha256"] = hash_file(bundle / "Contents/Info.plist")
    except (OSError, ValueError, plistlib.InvalidFileException) as error:
        record["classification"] = "keep_unknown"
        record["reason"] = str(error)
    return record


def command(arguments, allow_failure=False):
    try:
        result = subprocess.run([str(arg) for arg in arguments], stdout=subprocess.PIPE,
                                stderr=subprocess.STDOUT, universal_newlines=True, timeout=30)
    except subprocess.TimeoutExpired:
        raise RuntimeError("Command timed out: " + str(arguments[0]))
    if result.returncode and not allow_failure:
        raise RuntimeError("Command failed (" + str(result.returncode) + "): " + str(arguments[0]) + "\n" + result.stdout)
    return {"returncode": result.returncode, "output": result.stdout}


def active_under(source, uid):
    result = command(["/bin/ps", "-ww", "-axo", "pid=,uid=,comm="])
    matches = []
    for line in result["output"].splitlines():
        parts = line.strip().split(None, 2)
        if len(parts) != 3 or not parts[0].isdigit() or not parts[1].isdigit():
            continue
        if int(parts[1]) == uid and (parts[2] == str(source) or parts[2].startswith(str(source) + "/")):
            matches.append({"pid": int(parts[0]), "executable": parts[2]})
    return matches


def save_plan(state, plan):
    # Persist every transition before its next filesystem/registration effect.
    with tempfile.NamedTemporaryFile(mode="w", prefix=".plan-", suffix=".json", dir=str(state),
                                     delete=False, encoding="utf-8") as stream:
        json.dump(plan, stream, indent=2, ensure_ascii=False)
        stream.write("\n")
        stream.flush()
        os.fsync(stream.fileno())
        temporary = stream.name
    os.replace(temporary, str(state / "plan.json"))


def unchanged(action, home, uid):
    source = safe_owned_path(action["source"], home, uid)
    info = source.lstat()
    require({"device": info.st_dev, "inode": info.st_ino, "uid": info.st_uid} == action["source_identity"],
            "The source directory changed since the plan was saved.")
    bundle = Path(action["path"])
    read_bundle(bundle, home, uid)
    require(hash_file(bundle / "Contents/Info.plist") == action["info_sha256"], "The bundle metadata changed after planning.")
    executable = safe_owned_path(source / action["executable_relative"], home, uid)
    require(hash_file(executable) == action["executable_sha256"], "The executable changed after planning.")


def verify_moved(action, home, uid):
    destination = safe_owned_path(action["destination"], home, uid)
    info = destination.lstat()
    require({"device": info.st_dev, "inode": info.st_ino, "uid": info.st_uid} == action["source_identity"],
            "The moved directory does not have the original filesystem identity.")
    require(hash_file(destination / action["executable_relative"]) == action["executable_sha256"],
            "The moved executable differs from the planned original.")
    moved_bundle = destination / "CMake.app" if action["classification"] == "move_cmake_distribution" else destination
    require(hash_file(moved_bundle / "Contents/Info.plist") == action["info_sha256"], "The moved Info.plist differs from the original.")
    if action["classification"] == "move_cmake_distribution":
        cli = destination / action["executable_relative"]
        version = command([cli, "--version"])
        version_lines = version["output"].splitlines()
        require(version_lines and version_lines[0] == "cmake version " + CMAKE_VERSION,
                "The relocated CMake did not report the expected version.")
        command([cli, "--help-module", "CMakePrintHelpers"])
        command(["/usr/bin/codesign", "--verify", "--deep", "--strict", moved_bundle])
        action["verification"] = "same inode and hashes; CMake version, module lookup and code signature verified"
    else:
        action["verification"] = "same inode and executable/Info.plist hashes"


def apply_action(action, state, plan, home, uid):
    source = Path(action["source"])
    destination = Path(action["destination"])
    moved = False
    unregister_attempted = False
    try:
        unchanged(action, home, uid)
        safe_owned_path(destination, home, uid, existing=False)
        require(not os.path.lexists(str(destination)), "The destination already exists; it was not overwritten.")
        active = active_under(source, uid)
        require(not active, "A process is still using this source: " + json.dumps(active))
        if action["classification"] == "move_cmake_distribution":
            command(["/usr/bin/codesign", "--verify", "--deep", "--strict", action["path"]])
        action["status"] = "unregistering_exact_source_path"
        save_plan(state, plan)
        unregister_attempted = True
        action["unregister_result"] = command([LSREGISTER, "-u", action["path"]])
        action["status"] = "moving"
        save_plan(state, plan)
        destination.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        safe_owned_path(destination.parent, home, uid)
        require(not os.path.lexists(str(destination)), "The destination appeared during the operation.")
        # Atomic same-filesystem rename: no recursive copy/delete fallback.
        os.rename(str(source), str(destination))
        moved = True
        verify_moved(action, home, uid)
        action["status"] = "completed"
        save_plan(state, plan)
    except (OSError, ValueError, RuntimeError) as error:
        action["error"] = str(error)
        action["status"] = "failed"
        save_plan(state, plan)
        if moved:
            try:
                require(not os.path.lexists(str(source)), "The old source path is occupied; the archive was preserved at its destination.")
                os.rename(str(destination), str(source))
                moved = False
                action["rollback_move"] = "restored original path"
            except (OSError, ValueError) as rollback_error:
                action["rollback_move"] = str(rollback_error)
        if unregister_attempted and not moved and source.exists():
            # Restore only this exact bundle's registration after a failed move.
            try:
                action["rollback_registration"] = command([LSREGISTER, action["path"]], allow_failure=True)
            except RuntimeError as registration_error:
                action["rollback_registration"] = {"error": str(registration_error)}
        save_plan(state, plan)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--state-dir", required=True, help="A new private report directory inside the current user's home.")
    parser.add_argument("--apply", action="store_true", help="Apply the identified moves after persisting their plan.")
    args = parser.parse_args()
    require(sys.platform == "darwin", "Run this hook on the iMac.")
    uid = os.getuid()
    require(uid != 0 and os.geteuid() == uid, "Run as the signed-in user, without sudo.")
    home = Path(pwd.getpwuid(uid).pw_dir).resolve(strict=True)
    prototype = home / "Applications/UxPlay-Prueba-1.73.7"
    tools = home / "Library/Application Support/AirPlay/BuildTools.noindex"
    legacy = home / "Library/Application Support/AirPlay/LegacyApps.noindex"
    state = safe_owned_path(Path(args.state_dir).expanduser(), home, uid, existing=False)
    require(is_within(state, home / "Library/Caches/AirPlay") or is_within(state, home / "Library/Logs/AirPlay"),
            "The new report directory must be inside Library/Caches/AirPlay or Library/Logs/AirPlay.")
    require(not is_within(state, prototype) and not is_within(state, tools) and not is_within(state, legacy),
            "Keep the report directory outside all relocation sources and destinations.")
    require(not os.path.lexists(str(state)), "Use a new state directory; an existing report is not overwritten.")
    state.mkdir(mode=0o700, parents=True)
    os.chmod(str(state), 0o700)
    session = datetime.datetime.utcnow().strftime("%Y%m%d-%H%M%S") + "-" + str(os.getpid()) + "-" + uuid.uuid4().hex[:8]
    plan = {"schema": 1, "session": session, "uid": uid, "home": str(home),
            "prototype": str(prototype), "mode": "apply" if args.apply else "plan_only",
            "installed_app_is_excluded": "/Applications/AirPlay.app", "actions": [], "kept": [],
            "canonical_cmake": str(tools / CMAKE_DIST / "CMake.app/Contents/bin/cmake"),
            "libplist_prefix_unchanged": str(prototype / "dependencias"),
            "source_checkout_unchanged": str(prototype / "fuente")}
    save_plan(state, plan)
    if not prototype.exists():
        plan["result"] = "historical prototype absent; no changes"
        save_plan(state, plan)
        print(json.dumps({"plan": str(state / "plan.json"), "result": plan["result"]}))
        return 0
    safe_owned_path(prototype, home, uid)
    records = [classify(bundle, prototype, home, uid) for bundle in outer_bundles(prototype)]
    for record in records:
        if record["classification"] == "keep_unknown":
            plan["kept"].append(record)
            continue
        source = Path(record["source"])
        if record["classification"] == "move_cmake_distribution":
            extra_bundles = [other["path"] for other in records if other["path"] != record["path"] and is_within(other["path"], source)]
            if extra_bundles:
                record["reason"] = "Unexpected additional bundles in CMake distribution; the whole directory is kept."
                record["extra_bundles"] = extra_bundles
                plan["kept"].append(record)
                continue
            destination = tools / CMAKE_DIST
        else:
            destination = legacy / session / source.relative_to(prototype)
        safe_owned_path(destination, home, uid, existing=False)
        record["destination"] = str(destination)
        record["status"] = "kept_destination_exists" if os.path.lexists(str(destination)) else "planned"
        plan["actions"].append(record)
    save_plan(state, plan)
    require(LSREGISTER.is_file() and os.access(str(LSREGISTER), os.X_OK), "The macOS registration tool is unavailable.")
    help_result = command([LSREGISTER, "-h"], allow_failure=True)
    (state / "lsregister-help.txt").write_text(help_result["output"], encoding="utf-8")
    plan["lsregister_unregister_supported"] = bool(re.search(r"(?im)^\s*-u\b[^\n]*unregister", help_result["output"]))
    if args.apply:
        require(plan["lsregister_unregister_supported"], "This lsregister help does not document -u unregister; no moves were applied.")
        for action in plan["actions"]:
            if action["status"] == "planned":
                apply_action(action, state, plan, home, uid)
    failures = [a for a in plan["actions"] if a["status"] in ("failed", "kept_destination_exists")]
    plan["result"] = "completed_with_items_kept" if failures or plan["kept"] else "completed"
    if not args.apply:
        plan["result"] = "plan_only; no bundle or registration changed"
    plan["completed_moves"] = sum(a["status"] == "completed" for a in plan["actions"])
    save_plan(state, plan)
    print(json.dumps({"plan": str(state / "plan.json"), "result": plan["result"],
                      "completed_moves": plan["completed_moves"], "unknown_bundles_kept": len(plan["kept"]),
                      "failed_or_conflicting_moves": len(failures)}, ensure_ascii=False))
    return 2 if failures else 0


if __name__ == "__main__":
    os.umask(0o077)
    try:
        sys.exit(main())
    except (OSError, ValueError, RuntimeError, plistlib.InvalidFileException) as error:
        print("ERROR: " + str(error), file=sys.stderr)
        sys.exit(1)
