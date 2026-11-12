#!/usr/bin/env python3
"""Validate R CMD build output and record its source and checksum."""

import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import sys
import tarfile


def description_fields(text):
    return dict(re.findall(r"^(Package|Version):\s*(\S+)\s*$", text, re.MULTILINE))


source, build, output = map(Path, sys.argv[1:])
expected = description_fields((source / "DESCRIPTION").read_text())
package, version = expected["Package"], expected["Version"]
if not re.fullmatch(r"[A-Za-z][A-Za-z0-9.]*", package):
    raise ValueError("Unexpected package name")
if not re.fullmatch(r"[0-9][A-Za-z0-9.+-]*", version):
    raise ValueError("Unexpected package version")

archives = list(build.glob("*.tar.gz"))
if len(archives) != 1:
    raise ValueError(f"Expected one source tarball, found {len(archives)}")
with tarfile.open(archives[0], "r:gz") as archive:
    description = archive.extractfile(f"{package}/DESCRIPTION").read().decode()
    if description_fields(description) != expected:
        raise ValueError("Built DESCRIPTION does not match source DESCRIPTION")

branch = os.environ["GITHUB_REF_NAME"]
sha = os.environ["GITHUB_SHA"]
if not re.fullmatch(r"[0-9a-f]{40}", sha):
    raise ValueError("Unexpected commit SHA")
branch_label = re.sub(r"[^A-Za-z0-9._-]", "-", branch)[:60]
# The hash distinguishes branch names that normalize to the same filename.
branch_label += "-" + hashlib.sha256(branch.encode()).hexdigest()[:12]
run_id = int(os.environ["GITHUB_RUN_ID"])
attempt = int(os.environ["GITHUB_RUN_ATTEMPT"])
filename = f"{package}_{version}_{branch_label}_{sha}_{run_id}-{attempt}.tar.gz"
output.mkdir(parents=True, exist_ok=True)
shutil.copyfile(archives[0], output / filename)
digest = hashlib.sha256((output / filename).read_bytes()).hexdigest()
metadata = {
    "package": package,
    "version": version,
    "branch": branch,
    "sha": sha,
    "run_id": run_id,
    "run_number": int(os.environ["GITHUB_RUN_NUMBER"]),
    "run_attempt": attempt,
    "filename": filename,
    "sha256": digest,
}
(output / "source-build.json").write_text(json.dumps(metadata, indent=2) + "\n")
(output / f"{filename}.sha256").write_text(f"{digest}  {filename}\n")
print(json.dumps(metadata, indent=2))
