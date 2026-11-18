"""
Grades an answer to the task in retry_policy.hz with Haze.

    python grade.py '{"max_attempts": 5, "idempotent": true}'

Prints a JSON verdict and exits with 0 if the answer passes, 1 if it fails and 2 if it is malformed.
The verdict lists each requirement with Haze's exact result, as fractions, and the counterexample
for any requirement that fails, so a failed answer comes with the run that breaks it. The haze
command is taken from $HAZE, the PATH, or this repository's build.
"""
import json, os, pathlib, re, shutil, subprocess, sys, tempfile

HERE = pathlib.Path(__file__).resolve().parent
TASK = HERE / "retry_policy.hz"


def haze_binary():
    if os.environ.get("HAZE"):
        return os.environ["HAZE"]
    found = shutil.which("haze")
    if found:
        return found
    exe = "haze.exe" if os.name == "nt" else "haze"
    return str(HERE.parent.parent / ".lake" / "build" / "bin" / exe)


def malformed(reason):
    print(json.dumps({"passed": False, "error": reason}))
    sys.exit(2)


def main():
    try:
        answer = json.loads(sys.argv[1])
    except (IndexError, json.JSONDecodeError):
        malformed('expected an answer such as \'{"max_attempts": 5, "idempotent": true}\'')
    attempts, idempotent = answer.get("max_attempts"), answer.get("idempotent")
    if not isinstance(attempts, int) or isinstance(attempts, bool) or not 1 <= attempts <= 20:
        malformed("max_attempts must be a whole number from 1 to 20")
    if not isinstance(idempotent, bool):
        malformed("idempotent must be true or false")

    # put the answer in place of the reference answer; the requirements stay as written
    src = TASK.read_text(encoding="utf-8")
    src = re.sub(r"def max_attempts_answer : Num := .*", f"def max_attempts_answer : Num := {attempts}", src)
    src = re.sub(r"def idempotent_answer : Bool := .*", f"def idempotent_answer : Bool := {str(idempotent).lower()}", src)

    with tempfile.TemporaryDirectory() as tmp:
        path = pathlib.Path(tmp) / "submission.hz"
        path.write_text(src, encoding="utf-8")
        out = subprocess.run([haze_binary(), "--json", str(path)], capture_output=True, text=True, encoding="utf-8").stdout

    checks = []
    for line in out.splitlines():
        record = json.loads(line)
        if record.get("severity") == "error" and record.get("kind") not in ("claim", "theorem"):
            malformed(record["message"])
        if record.get("kind") in ("claim", "theorem"):
            checks.append({key: record.get(key) for key in
                           ("name", "accepted", "belief", "plausibility", "counterexample")})
    passed = bool(checks) and all(c["accepted"] for c in checks)
    print(json.dumps({"passed": passed, "answer": answer, "requirements": checks}, indent=1))
    sys.exit(0 if passed else 1)


if __name__ == "__main__":
    main()
