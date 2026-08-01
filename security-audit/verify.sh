#!/usr/bin/env bash
# =============================================================================
# verify.sh - the executable sixteen-check verification harness
# =============================================================================
# Artifact : security-audit/verify.sh
# Realizes : Directive 10. This is the mechanism by which the five-layer
#            assessment PROVES itself rather than asserting its own
#            correctness. Authoring the checks is not sufficient - the harness
#            is generated AND executed, and its captured output is published
#            alongside it as security-audit/verify-output.txt.
#
# Contract : - Accepts the audit directory as $1, defaulting to the directory
#              this script lives in, so it runs correctly from any CWD.
#            - Each check prints EXACTLY one line, either
#                  PASS <N>: <reason>
#              or  FAIL <N>: <reason>
#              and nothing else. No banners, no colour, no progress output.
#            - A FAIL line NEVER carries an empty reason. An unexplained
#              failure is itself a silent failure, which the assessment's
#              global rules forbid, so every JSON read is a guarded load that
#              reports the parse error verbatim, and every check body runs
#              inside a guard that turns an unexpected exception into an
#              explicit FAIL line rather than into silence.
#            - Exits with the COUNT OF FAILURES. Zero failures means exit 0.
#            - Emits no escape byte of any kind. Check 12 greps every file in
#              the audit directory for the escape byte, so a colourising
#              harness would fail its own check; reasons are additionally
#              sanitised of control bytes before they are printed.
#            - READ-ONLY. The harness opens files for reading only. It never
#              writes, repairs, regenerates or reorders any artifact it
#              inspects. If a check fails, the remedy is to fix the artifact
#              and re-run - never to edit this script or its captured output.
#
# Tooling  : Bash plus inline python3. jq is deliberately absent from the
#            execution host, so every JSON assertion is written in python3.
#            No other tool is invoked: the harness has no dependency on
#            semgrep, osv-scanner, ripgrep, node, yarn, go or curl.
#
# Exactly sixteen checks, numbered 1 through 16, in order. None is weakened,
# skipped or reordered, and there is no seventeenth.
# =============================================================================

set -u

SCRIPT_PATH="${BASH_SOURCE[0]}"
SCRIPT_DIR="$(cd "$(dirname "$SCRIPT_PATH")" && pwd)"
AUDIT_DIR="${1:-$SCRIPT_DIR}"
HARNESS_BASENAME="$(basename "$SCRIPT_PATH")"

# -----------------------------------------------------------------------------
# Shared python prelude. Prepended to every check body so that the guarded
# loads, the single-line emitter and the inventory parser are defined once and
# behave identically in all sixteen checks.
# -----------------------------------------------------------------------------
PY_PRELUDE=$(cat <<'PRELUDE_EOF'
import hashlib
import json
import os
import re
import sys

AUDIT = os.environ["AUDIT_DIR"]
HARNESS = os.environ.get("HARNESS_BASENAME", "verify.sh")
N = int(os.environ["CHECK_NO"])

# The escape byte is built from its code point so that this file contains no
# literal escape byte of its own. Check 12 also excludes the harness by name.
ESC = chr(27)
CONTROL_CLASS = "[" + "".join(chr(c) for c in list(range(0, 32)) + [127]) + "]"
CONTROL = re.compile(CONTROL_CLASS)

SEVERITIES = ("critical", "high", "medium", "low")
VERDICTS = ("ERROR", "BLOCK", "WARN", "PASS")
DETERMINISTIC_STATUS_KEYS = (
    "layer_0_status",
    "layer_2_status",
    "layer_3a_status",
    "layer_4_status",
)
# tool name, normalized artifact, its *_status key, its short-form status key
LAYER_FILES = (
    ("arch-audit", "findings-layer-1-arch.json", "layer_1_status", "layer_1"),
    ("semgrep", "findings-layer-2-semgrep.json", "layer_2_status", "layer_2"),
    ("taint-analysis", "findings-layer-3b-taint.json", "layer_3b_status", "layer_3b"),
    ("osv-scanner", "findings-layer-4-osv.json", "layer_4_status", "layer_4"),
)
# Sink categories that are structurally inapplicable to a given primary
# language are expected to be empty and do not trigger a failure. No sink
# category is structurally inapplicable to a TypeScript codebase, so this map
# is empty for this repository and the carve-out is never exercised here.
INAPPLICABLE_SINK_CATEGORIES = {}


def clean(text):
    """Collapse whitespace and strip control bytes out of a reason string."""
    return " ".join(CONTROL.sub(" ", str(text)).split())


def emit(ok, reason):
    """Print exactly one PASS/FAIL line and exit with the check's status."""
    reason = clean(reason)
    if not reason:
        ok = False
        reason = (
            "the check body produced no reason, which is itself a defect "
            "because an unexplained result is a silent failure"
        )
    sys.stdout.write("%s %d: %s\n" % ("PASS" if ok else "FAIL", N, reason))
    sys.stdout.flush()
    sys.exit(0 if ok else 1)


def guard(body):
    """Run a check body so that it can never terminate without a result line."""
    try:
        body()
    except SystemExit:
        raise
    except BaseException as exc:  # noqa: BLE001 - an explicit reason beats silence
        emit(False, "the check aborted with an unexpected %s - %s" % (type(exc).__name__, exc))
    emit(False, "the check returned without emitting a result, which is itself a defect")


def oserror_reason(exc):
    """Describe an OSError without echoing the operating system's own path.

    The path in an OSError message is whatever was passed on the command line
    and can therefore be host-specific. Every reason this harness prints must
    stay portable, so only the errno description is reported and the artifact is
    named separately by the caller.
    """
    return exc.strerror or type(exc).__name__


def apath(name):
    return os.path.join(AUDIT, name)


def read_text(name):
    """Guarded text read. Returns (text, error_reason)."""
    target = apath(name)
    if not os.path.exists(target):
        return None, "%s does not exist in the audit directory" % name
    if not os.path.isfile(target):
        return None, "%s exists but is not a regular file" % name
    try:
        with open(target, encoding="utf-8") as handle:
            return handle.read(), None
    except UnicodeDecodeError as exc:
        return None, "%s is not valid UTF-8 - %s" % (name, exc.reason)
    except OSError as exc:
        return None, "%s could not be read - %s" % (name, oserror_reason(exc))


def load_json(name):
    """Guarded JSON read. Returns (object, error_reason)."""
    text, err = read_text(name)
    if err:
        return None, err
    try:
        return json.loads(text), None
    except json.JSONDecodeError as exc:
        return None, "%s is not valid JSON - %s" % (name, exc)


def load_array(name):
    obj, err = load_json(name)
    if err:
        return None, err
    if not isinstance(obj, list):
        return None, "%s parses but is a %s rather than a JSON array" % (name, type(obj).__name__)
    return obj, None


def load_ledger():
    obj, err = load_json("layer-status.json")
    if err:
        return None, err
    if not isinstance(obj, dict):
        return None, "layer-status.json parses but is a %s rather than a JSON object" % type(obj).__name__
    return obj, None


def documented_error(status_key):
    """True only when the ledger explicitly documents that layer as ERROR.

    Status is resolved BEFORE any attempt to open the layer's artifact, so a
    layer documented ERROR never causes an open of a file that is legitimately
    absent. A missing or unreadable ledger yields False: absence is never read
    as a documented ERROR, and never as an implicit OK either.
    """
    ledger, err = load_ledger()
    if err:
        return False
    return ledger.get(status_key) == "ERROR"


def profile_fields():
    """Parse the flat key: value profile. Returns (fields, error_reason)."""
    text, err = read_text("codebase-profile.txt")
    if err:
        return None, err
    fields = {}
    for line in text.splitlines():
        match = re.match(r"^([a-z0-9_]+):[ \t]*(.*)$", line)
        if match and match.group(1) not in fields:
            fields[match.group(1)] = match.group(2).strip()
    return fields, None


def parse_rows(text, category_max):
    """Parse inventory rows as <file>:<line>:<category>:<text>.

    Split on the FIRST THREE COLONS ONLY. The text field legitimately contains
    colons - a CSP header value carries both a colon and a semicolon, and a
    cookie attribute assignment carries a colon - so every colon after the
    third belongs to the text and is preserved.

    Returns (rows, malformed) where malformed is a list of (line_no, reason).
    """
    rows = []
    malformed = []
    for index, line in enumerate(text.splitlines(), 1):
        if not line:
            malformed.append((index, "the line is empty"))
            continue
        parts = line.split(":", 3)
        if len(parts) != 4:
            malformed.append((index, "fewer than four colon-separated fields"))
            continue
        located, line_field, category_field, payload = parts
        if not located:
            malformed.append((index, "the path field is empty"))
        elif not (line_field.isdigit() and int(line_field) > 0):
            malformed.append((index, "the line field is not a positive integer"))
        elif not (category_field.isdigit() and 1 <= int(category_field) <= category_max):
            malformed.append((index, "the category field is not an integer in 1-%d" % category_max))
        elif not payload.strip():
            malformed.append((index, "the text field is blank"))
        else:
            rows.append((located, int(line_field), int(category_field), payload))
    return rows, malformed


def unsafe(paths):
    """Paths that make the colon-delimited row format ambiguous.

    A path containing a colon, a carriage return, a line feed, a NUL or any
    other control byte would let a row parse into a different path, line and
    category than the one it records. Such a path is rejected rather than
    interpreted: the format has no escaping, so the only safe response is to
    fail closed.
    """
    return sorted({p for p in paths if ":" in p or CONTROL.search(p)})


def repo_root():
    """Locate the repository root above the audit directory, or None."""
    current = os.path.abspath(AUDIT)
    for _ in range(8):
        parent = os.path.dirname(current)
        if not parent or parent == current:
            return None
        current = parent
        marker = os.path.join(current, ".git")
        if os.path.isdir(marker) or os.path.isfile(marker):
            return current
    return None


def findings_sources():
    """The findings arrays a whole-corpus check must scan, plus their errors.

    A layer documented ERROR is skipped by status BEFORE its artifact is
    opened, and is reported as skipped rather than as missing.
    """
    loaded = []
    errors = []
    skipped = []
    for tool, name, status_key, _short in LAYER_FILES:
        if documented_error(status_key):
            skipped.append(name)
            continue
        arr, err = load_array(name)
        if err:
            errors.append(err)
        else:
            loaded.append((name, arr))
    merged, err = load_array("findings-merged.json")
    if err:
        errors.append(err)
    else:
        body = [r for r in merged if isinstance(r, dict) and "_summary" not in r]
        loaded.append(("findings-merged.json body", body))
    return loaded, errors, skipped
PRELUDE_EOF
)

# -----------------------------------------------------------------------------
# Check driver. Streams the shared prelude followed by the check body into
# python3 and converts the interpreter's exit status into a failure tally.
# -----------------------------------------------------------------------------
FAILURES=0

py() {
  { printf '%s\n' "$PY_PRELUDE"; cat; } | CHECK_NO="$1" \
    AUDIT_DIR="$AUDIT_DIR" HARNESS_BASENAME="$HARNESS_BASENAME" python3 -
}

run() {
  if ! py "$@"; then
    FAILURES=$((FAILURES + 1))
  fi
}

# --- 1 -----------------------------------------------------------------------
# codebase-profile.txt exists with primary_language field populated.
run 1 <<'CHECK_EOF'
def body():
    fields, err = profile_fields()
    if err:
        emit(False, err)
    language = fields.get("primary_language", "")
    if not language:
        emit(False, "codebase-profile.txt exists but carries no populated primary_language field")
    mandated = [
        "primary_language", "secondary_languages", "frameworks", "package_ecosystems",
        "lockfiles", "source_file_count", "exclude_dirs",
    ]
    blank = [key for key in mandated if not fields.get(key)]
    if blank:
        emit(False, "codebase-profile.txt reports primary_language %s but these mandated fields are absent or blank: %s"
             % (language, ", ".join(blank)))
    emit(True, "codebase-profile.txt exists and primary_language is populated (%s); all seven mandated profile fields carry a value"
         % language)


guard(body)
CHECK_EOF

# --- 2 -----------------------------------------------------------------------
# findings-layer-1-arch.json exists, is a valid JSON array, and contains
# findings referencing all 10 Layer 1 architectural categories.
run 2 <<'CHECK_EOF'
def body():
    arr, err = load_array("findings-layer-1-arch.json")
    if err:
        emit(False, err)
    if not arr:
        emit(False, "findings-layer-1-arch.json is a valid but empty array, so no architectural category is covered")
    seen = set()
    untyped = 0
    for record in arr:
        if not isinstance(record, dict):
            untyped += 1
            continue
        category = record.get("category")
        if isinstance(category, bool) or not isinstance(category, int):
            untyped += 1
            continue
        seen.add(category)
    if untyped:
        emit(False, "findings-layer-1-arch.json has %d of %d records without an integer category field, so category coverage is not decidable"
             % (untyped, len(arr)))
    missing = [c for c in range(1, 11) if c not in seen]
    if missing:
        emit(False, "findings-layer-1-arch.json parses as an array of %d records but these Layer 1 categories carry no finding: %s"
             % (len(arr), ", ".join(str(c) for c in missing)))
    stray = sorted(c for c in seen if c < 1 or c > 10)
    if stray:
        emit(False, "findings-layer-1-arch.json carries categories outside the architectural range 1-10: %s"
             % ", ".join(str(c) for c in stray))
    emit(True, "findings-layer-1-arch.json is a valid JSON array of %d records and the additive integer category field covers all 10 architectural categories 1-10"
         % len(arr))


guard(body)
CHECK_EOF

# --- 3 -----------------------------------------------------------------------
# findings-layer-2-semgrep.json exists and is a valid JSON array, or
# layer_2_status is a documented ERROR.
run 3 <<'CHECK_EOF'
def body():
    if documented_error("layer_2_status"):
        emit(True, "layer-status.json documents layer_2_status ERROR, so findings-layer-2-semgrep.json may legitimately be absent and is not opened")
    arr, err = load_array("findings-layer-2-semgrep.json")
    if err:
        emit(False, "%s, and layer-status.json does not document layer_2_status as ERROR, so the absence is not permitted" % err)
    emit(True, "findings-layer-2-semgrep.json exists and is a valid JSON array of %d records; layer_2_status is not a documented ERROR, so the artifact is required and present"
         % len(arr))


guard(body)
CHECK_EOF

# --- 4 -----------------------------------------------------------------------
# sink-inventory.txt exists, is non-empty, every line matches
# <file>:<line>:<category>:<text>, and it covers all 19 sink categories
# applicable to the detected primary_language.
run 4 <<'CHECK_EOF'
def body():
    text, err = read_text("sink-inventory.txt")
    if err:
        emit(False, err)
    rows, malformed = parse_rows(text, 19)
    if not rows and not malformed:
        emit(False, "sink-inventory.txt exists but is empty, so no sink category is covered")
    if malformed:
        first = malformed[0]
        emit(False, "sink-inventory.txt has %d row(s) that do not match <file>:<line>:<category>:<text> on the first-three-colon split; the first is line %d - %s"
             % (len(malformed), first[0], first[1]))
    paths = {row[0] for row in rows}
    ambiguous = unsafe(paths)
    if ambiguous:
        emit(False, "sink-inventory.txt carries %d path(s) containing a colon or a control byte, which makes the row format ambiguous and must fail Layer 3a closed; the first is %r"
             % (len(ambiguous), ambiguous[0]))
    fields, perr = profile_fields()
    language = (fields or {}).get("primary_language", "")
    exempt = set(INAPPLICABLE_SINK_CATEGORIES.get(language, ()))
    seen = {row[2] for row in rows}
    missing = [c for c in range(1, 20) if c not in seen and c not in exempt]
    if missing:
        emit(False, "sink-inventory.txt has %d valid rows but these sink categories have zero entries and are not structurally inapplicable to %s: %s"
             % (len(rows), language or "the detected language", ", ".join(str(c) for c in missing)))
    root = repo_root()
    if root is None:
        roundtrip = "the on-disk path round-trip was not evaluated because no repository root was found above the audit directory"
    else:
        absent = sorted(p for p in paths if not os.path.exists(os.path.join(root, p)))
        if absent:
            emit(False, "sink-inventory.txt records %d path(s) that do not resolve to a file in the repository, so a row cannot be proven unambiguous; the first is %s"
                 % (len(absent), absent[0]))
        roundtrip = "all %d distinct paths resolve to a real file in the repository" % len(paths)
    exempt_note = ""
    if exempt:
        exempt_note = "; categories structurally inapplicable to %s and therefore exempt: %s" % (
            language, ", ".join(str(c) for c in sorted(exempt)))
    if perr:
        exempt_note += "; codebase-profile.txt was unreadable so no category was treated as structurally inapplicable"
    emit(True, "sink-inventory.txt has %d rows, 100 percent format-valid on the first-three-colon split, covering all 19 sink categories, with zero paths carrying a delimiter or control byte and %s%s"
         % (len(rows), roundtrip, exempt_note))


guard(body)
CHECK_EOF

# --- 5 -----------------------------------------------------------------------
# mitigation-inventory.txt exists, is non-empty, covers all 9 mitigation
# categories.
run 5 <<'CHECK_EOF'
def body():
    text, err = read_text("mitigation-inventory.txt")
    if err:
        emit(False, err)
    rows, malformed = parse_rows(text, 9)
    if not rows and not malformed:
        emit(False, "mitigation-inventory.txt exists but is empty, so no mitigation category is covered")
    if malformed:
        first = malformed[0]
        emit(False, "mitigation-inventory.txt has %d row(s) that do not match <file>:<line>:<category>:<text> on the first-three-colon split; the first is line %d - %s"
             % (len(malformed), first[0], first[1]))
    ambiguous = unsafe({row[0] for row in rows})
    if ambiguous:
        emit(False, "mitigation-inventory.txt carries %d path(s) containing a colon or a control byte, which makes the row format ambiguous and must fail Layer 3a closed; the first is %r"
             % (len(ambiguous), ambiguous[0]))
    seen = {row[2] for row in rows}
    missing = [c for c in range(1, 10) if c not in seen]
    if missing:
        emit(False, "mitigation-inventory.txt has %d valid rows but these mitigation categories have zero entries: %s"
             % (len(rows), ", ".join(str(c) for c in missing)))
    emit(True, "mitigation-inventory.txt has %d rows, all format-valid, covering all 9 mitigation categories, with zero paths carrying a delimiter or control byte"
         % len(rows))


guard(body)
CHECK_EOF

# --- 6 -----------------------------------------------------------------------
# sink-inventory-test.txt and mitigation-inventory-test.txt exist.
run 6 <<'CHECK_EOF'
def body():
    report = []
    for name in ("sink-inventory-test.txt", "mitigation-inventory-test.txt"):
        target = apath(name)
        if not os.path.exists(target):
            emit(False, "%s does not exist in the audit directory, so the test partition of the inventory is missing" % name)
        if not os.path.isfile(target):
            emit(False, "%s exists but is not a regular file" % name)
        text, err = read_text(name)
        if err:
            emit(False, err)
        report.append("%s (%d rows)" % (name, len(text.splitlines())))
    emit(True, "both test-partition inventories exist as regular files: %s" % " and ".join(report))


guard(body)
CHECK_EOF

# --- 7 -----------------------------------------------------------------------
# findings-layer-3b-taint.json exists, is a valid JSON array, contains findings
# for all 19 sink categories.
run 7 <<'CHECK_EOF'
def body():
    arr, err = load_array("findings-layer-3b-taint.json")
    if err:
        emit(False, err)
    if not arr:
        emit(False, "findings-layer-3b-taint.json is a valid but empty array, so no sink category is covered")
    seen = set()
    untyped = 0
    for record in arr:
        if not isinstance(record, dict):
            untyped += 1
            continue
        category = record.get("category")
        if isinstance(category, bool) or not isinstance(category, int):
            untyped += 1
            continue
        seen.add(category)
    if untyped:
        emit(False, "findings-layer-3b-taint.json has %d of %d records without an integer category field, so category coverage is not decidable"
             % (untyped, len(arr)))
    missing = [c for c in range(1, 20) if c not in seen]
    if missing:
        emit(False, "findings-layer-3b-taint.json parses as an array of %d records but these Layer 3b sink categories carry no record: %s"
             % (len(arr), ", ".join(str(c) for c in missing)))
    stray = sorted(c for c in seen if c < 1 or c > 19)
    if stray:
        emit(False, "findings-layer-3b-taint.json carries categories outside the sink range 1-19: %s"
             % ", ".join(str(c) for c in stray))
    emit(True, "findings-layer-3b-taint.json is a valid JSON array of %d records and the additive integer category field, in Layer 3b sink numbering, covers all 19 categories 1-19"
         % len(arr))


guard(body)
CHECK_EOF

# --- 8 -----------------------------------------------------------------------
# Every Layer 3b finding has a gateBlocking field; every finding where
# gateBlocking is false has a non-empty demotionReason.
run 8 <<'CHECK_EOF'
def body():
    arr, err = load_array("findings-layer-3b-taint.json")
    if err:
        emit(False, err)
    if not arr:
        emit(False, "findings-layer-3b-taint.json is a valid but empty array, so no gateBlocking field can be asserted")
    missing_flag = []
    not_boolean = []
    blank_reason = []
    blocking = 0
    advisory = 0
    for index, record in enumerate(arr):
        if not isinstance(record, dict):
            not_boolean.append(index)
            continue
        if "gateBlocking" not in record:
            missing_flag.append(index)
            continue
        flag = record["gateBlocking"]
        if not isinstance(flag, bool):
            not_boolean.append(index)
            continue
        if flag:
            blocking += 1
            continue
        advisory += 1
        reason = record.get("demotionReason")
        if not isinstance(reason, str) or not reason.strip():
            blank_reason.append(index)
    if missing_flag:
        emit(False, "%d Layer 3b record(s) have no gateBlocking field; the first is index %d"
             % (len(missing_flag), missing_flag[0]))
    if not_boolean:
        emit(False, "%d Layer 3b record(s) carry a non-boolean gateBlocking value or are not objects; the first is index %d"
             % (len(not_boolean), not_boolean[0]))
    if blank_reason:
        emit(False, "%d advisory Layer 3b record(s) have a missing or whitespace-only demotionReason; the first is index %d"
             % (len(blank_reason), blank_reason[0]))
    emit(True, "all %d Layer 3b records carry a boolean gateBlocking field (%d gate-blocking, %d advisory) and every one of the %d advisories carries a non-blank demotionReason"
         % (len(arr), blocking, advisory, advisory))


guard(body)
CHECK_EOF

# --- 9 -----------------------------------------------------------------------
# All severity fields across all JSON files use only critical|high|medium|low.
run 9 <<'CHECK_EOF'
def body():
    sources, errors, skipped = findings_sources()
    if errors:
        emit(False, "; ".join(errors))
    offenders = []
    scanned = 0
    for name, arr in sources:
        for index, record in enumerate(arr):
            if not isinstance(record, dict) or "severity" not in record:
                continue
            scanned += 1
            value = record["severity"]
            if value not in SEVERITIES:
                offenders.append("%s index %d carries severity %r" % (name, index, value))
    for name in ("findings-merged.json", "baseline.json"):
        obj, err = load_json(name)
        if err or not isinstance(obj, (dict, list)):
            continue
        holder = obj[0] if isinstance(obj, list) and obj and isinstance(obj[0], dict) else obj
        if not isinstance(holder, dict):
            continue
        summary = holder.get("_summary", holder)
        distribution = summary.get("by_severity") if isinstance(summary, dict) else None
        if isinstance(distribution, dict):
            for key in distribution:
                scanned += 1
                if key not in SEVERITIES:
                    offenders.append("%s by_severity carries key %r" % (name, key))
    if offenders:
        emit(False, "%d severity value(s) fall outside the closed vocabulary critical|high|medium|low: %s"
             % (len(offenders), "; ".join(offenders[:3])))
    note = ""
    if skipped:
        note = "; skipped by documented ERROR status: %s" % ", ".join(skipped)
    emit(True, "all %d severity values across every findings array, the merged body and both by_severity distributions use only critical|high|medium|low; provenance fields that deliberately record an upstream tool's own vocabulary, such as native_severity and sarif_level, are not severity fields of the unified schema and are excluded%s"
         % (scanned, note))


guard(body)
CHECK_EOF

# --- 10 ----------------------------------------------------------------------
# findings-layer-4-osv.json exists and is a valid JSON array, or
# layer_4_status is a documented ERROR.
run 10 <<'CHECK_EOF'
def body():
    if documented_error("layer_4_status"):
        emit(True, "layer-status.json documents layer_4_status ERROR, so findings-layer-4-osv.json may legitimately be absent and is not opened")
    arr, err = load_array("findings-layer-4-osv.json")
    if err:
        emit(False, "%s, and layer-status.json does not document layer_4_status as ERROR, so the absence is not permitted" % err)
    emit(True, "findings-layer-4-osv.json exists and is a valid JSON array of %d records; layer_4_status is not a documented ERROR, so the artifact is required and present"
         % len(arr))


guard(body)
CHECK_EOF

# --- 11 ----------------------------------------------------------------------
# findings-merged.json exists, is valid JSON, and its summary counts match the
# sum of the layer files. A layer documented ERROR contributes ZERO.
run 11 <<'CHECK_EOF'
def body():
    merged, err = load_array("findings-merged.json")
    if err:
        emit(False, err)
    if not merged or not isinstance(merged[0], dict) or "_summary" not in merged[0]:
        emit(False, "findings-merged.json parses as an array but its first element is not a _summary header object")
    summary = merged[0]["_summary"]
    if not isinstance(summary, dict):
        emit(False, "findings-merged.json _summary is a %s rather than an object" % type(summary).__name__)
    expected = {}
    problems = []
    errored = []
    for tool, name, status_key, _short in LAYER_FILES:
        if documented_error(status_key):
            expected[tool] = 0
            errored.append(tool)
            continue
        arr, load_err = load_array(name)
        if load_err:
            problems.append(load_err)
            continue
        expected[tool] = len(arr)
    if problems:
        emit(False, "; ".join(problems))
    by_layer = summary.get("by_layer")
    if not isinstance(by_layer, dict):
        emit(False, "findings-merged.json _summary.by_layer is missing or is not an object, so counts cannot be reconciled")
    drift = ["%s reports %r but the layer array holds %d" % (tool, by_layer.get(tool), count)
             for tool, count in expected.items() if by_layer.get(tool) != count]
    if drift:
        emit(False, "findings-merged.json _summary.by_layer disagrees with the layer arrays: %s" % "; ".join(drift))
    total = sum(expected.values())
    if summary.get("total_findings") != total:
        emit(False, "findings-merged.json _summary.total_findings is %r but the layer arrays sum to %d, with layers documented ERROR contributing zero"
             % (summary.get("total_findings"), total))
    body_records = [r for r in merged[1:] if isinstance(r, dict)]
    if len(body_records) != len(merged) - 1:
        emit(False, "findings-merged.json carries %d array element(s) after _summary that are not objects"
             % (len(merged) - 1 - len(body_records)))
    if summary.get("unique_findings") != len(body_records):
        emit(False, "findings-merged.json _summary.unique_findings is %r but the merged body holds %d records"
             % (summary.get("unique_findings"), len(body_records)))
    distribution = summary.get("by_severity")
    if not isinstance(distribution, dict) or sum(distribution.values()) != len(body_records):
        emit(False, "findings-merged.json _summary.by_severity sums to %r but the merged body holds %d records"
             % (sum(distribution.values()) if isinstance(distribution, dict) else None, len(body_records)))
    note = "; layers documented ERROR and therefore contributing zero: %s" % ", ".join(errored) if errored else ""
    emit(True, "findings-merged.json is valid JSON whose _summary reconciles exactly: total_findings %d equals the sum of the four layer arrays, by_layer matches each array length, unique_findings %d equals the merged body length, and by_severity sums to the same %d%s"
         % (total, len(body_records), len(body_records), note))


guard(body)
CHECK_EOF

# --- 12 ----------------------------------------------------------------------
# No ANSI escape sequences in any output file. The harness itself is excluded,
# because it must be able to name the escape byte in order to search for it.
run 12 <<'CHECK_EOF'
def body():
    if not os.path.isdir(AUDIT):
        emit(False, "the audit directory %s does not exist, so no output file could be scanned" % AUDIT)
    offenders = []
    scanned = 0
    unreadable = []
    for root, dirs, files in os.walk(AUDIT):
        dirs.sort()
        for name in sorted(files):
            target = os.path.join(root, name)
            relative = os.path.relpath(target, AUDIT)
            if name == HARNESS:
                continue
            try:
                with open(target, "rb") as handle:
                    blob = handle.read()
            except OSError as exc:
                unreadable.append("%s (%s)" % (relative, oserror_reason(exc)))
                continue
            scanned += 1
            if ESC.encode("ascii") in blob:
                offenders.append(relative)
    if unreadable:
        emit(False, "%d output file(s) could not be read for the escape-byte scan: %s"
             % (len(unreadable), "; ".join(unreadable[:3])))
    if offenders:
        emit(False, "%d output file(s) contain the escape byte 0x1b: %s"
             % (len(offenders), ", ".join(offenders[:5])))
    emit(True, "all %d output files under the audit directory are free of the escape byte 0x1b; the harness itself is excluded because it must name that byte in order to search for it"
         % scanned)


guard(body)
CHECK_EOF

# --- 13 ----------------------------------------------------------------------
# No finding in any JSON file has an empty or missing description field.
run 13 <<'CHECK_EOF'
def body():
    sources, errors, skipped = findings_sources()
    if errors:
        emit(False, "; ".join(errors))
    blank = []
    overlong = []
    scanned = 0
    longest = 0
    for name, arr in sources:
        for index, record in enumerate(arr):
            if not isinstance(record, dict):
                continue
            scanned += 1
            value = record.get("description")
            if not isinstance(value, str) or not value.strip():
                blank.append("%s index %d" % (name, index))
                continue
            longest = max(longest, len(value))
            if len(value) > 200:
                overlong.append("%s index %d is %d characters" % (name, index, len(value)))
    if blank:
        emit(False, "%d finding(s) have a missing, non-string or whitespace-only description: %s"
             % (len(blank), "; ".join(blank[:3])))
    if overlong:
        emit(False, "%d finding description(s) exceed the 200-character bound: %s"
             % (len(overlong), "; ".join(overlong[:3])))
    note = "; skipped by documented ERROR status: %s" % ", ".join(skipped) if skipped else ""
    emit(True, "all %d findings across every layer array and the merged body carry a non-blank description within the 200-character bound; the longest is %d characters%s"
         % (scanned, longest, note))


guard(body)
CHECK_EOF

# --- 14 ----------------------------------------------------------------------
# findings-merged.json contains a gate_verdict field whose value is ERROR,
# BLOCK, WARN or PASS.
run 14 <<'CHECK_EOF'
def body():
    merged, err = load_array("findings-merged.json")
    if err:
        emit(False, err)
    if not merged or not isinstance(merged[0], dict) or "_summary" not in merged[0]:
        emit(False, "findings-merged.json parses as an array but its first element is not a _summary header object, so gate_verdict has no defined location")
    summary = merged[0]["_summary"]
    if not isinstance(summary, dict):
        emit(False, "findings-merged.json _summary is a %s rather than an object" % type(summary).__name__)
    if "gate_verdict" in summary:
        verdict = summary["gate_verdict"]
        where = "_summary.gate_verdict"
    elif "gate_verdict" in merged[0]:
        verdict = merged[0]["gate_verdict"]
        where = "the header object's gate_verdict"
    else:
        emit(False, "findings-merged.json carries no gate_verdict field in its header object or its _summary")
    if verdict not in VERDICTS:
        emit(False, "findings-merged.json %s is %r, which is outside the closed set ERROR, BLOCK, WARN, PASS" % (where, verdict))
    emit(True, "findings-merged.json carries %s with the value %s, which is inside the closed set ERROR, BLOCK, WARN, PASS" % (where, verdict))


guard(body)
CHECK_EOF

# --- 15 ----------------------------------------------------------------------
# No pre-agent step has a silent failure. A missing status is a FAIL, never an
# implicit success. The ledger's own artifact manifest is additionally
# re-measured, which proves internal consistency but never authenticity.
run 15 <<'CHECK_EOF'
def body():
    ledger, err = load_ledger()
    if err:
        emit(False, err)
    absent = [key for key in DETERMINISTIC_STATUS_KEYS if key not in ledger]
    if absent:
        emit(False, "layer-status.json records no value for %s, and a missing pre-agent status is a failure rather than an implicit success"
             % ", ".join(absent))
    invalid = ["%s is %r" % (key, ledger[key]) for key in DETERMINISTIC_STATUS_KEYS
               if ledger[key] not in ("OK", "ERROR")]
    if invalid:
        emit(False, "layer-status.json carries a pre-agent status outside the vocabulary OK, ERROR: %s" % "; ".join(invalid))
    short_form = {"layer_0_status": "layer_0", "layer_2_status": "layer_2",
                  "layer_3a_status": "layer_3a", "layer_4_status": "layer_4"}
    twin_drift = ["%s is %r but %s is %r" % (key, ledger[key], twin, ledger.get(twin))
                  for key, twin in short_form.items() if twin in ledger and ledger[twin] != ledger[key]]
    if twin_drift:
        emit(False, "layer-status.json disagrees with itself between a pre-agent status key and its short-form twin: %s" % "; ".join(twin_drift))
    merged, merr = load_array("findings-merged.json")
    reported = None
    if not merr and merged and isinstance(merged[0], dict) and isinstance(merged[0].get("_summary"), dict):
        reported = merged[0]["_summary"].get("layer_status")
    if reported is None:
        emit(False, "findings-merged.json does not expose _summary.layer_status, so drift against the ledger cannot be excluded%s"
             % ((" - " + merr) if merr else ""))
    if not isinstance(reported, dict):
        emit(False, "findings-merged.json _summary.layer_status is a %s rather than an object" % type(reported).__name__)
    drift = []
    for key, twin in short_form.items():
        if twin in reported and reported[twin] != ledger[key]:
            drift.append("%s is %r in the ledger but %r in the merged summary" % (twin, ledger[key], reported[twin]))
    for twin in ("layer_1", "layer_3b"):
        if twin in reported and twin in ledger and reported[twin] != ledger[twin]:
            drift.append("%s is %r in the ledger but %r in the merged summary" % (twin, ledger[twin], reported[twin]))
    unsourced = sorted(key for key in reported if key not in ledger)
    if drift:
        emit(False, "findings-merged.json _summary.layer_status drifts from layer-status.json: %s" % "; ".join(drift))
    if unsourced:
        emit(False, "findings-merged.json _summary.layer_status reports %s, which the ledger does not record, so those values are invented rather than sourced"
             % ", ".join(unsourced))
    manifest = (((ledger.get("ledger") or {}).get("provenance") or {}).get("attested_outputs") or {})
    mismatched = []
    unreadable = []
    for relative in sorted(manifest):
        expected = (manifest[relative] or {}).get("sha256")
        target = apath(relative)
        try:
            with open(target, "rb") as handle:
                measured = hashlib.sha256(handle.read()).hexdigest()
        except OSError as exc:
            unreadable.append("%s (%s)" % (relative, oserror_reason(exc)))
            continue
        if measured != expected:
            mismatched.append(relative)
    if unreadable:
        emit(False, "%d artifact(s) named in the ledger's attested manifest could not be read: %s"
             % (len(unreadable), "; ".join(unreadable[:3])))
    if mismatched:
        emit(False, "%d artifact(s) no longer match the digest the ledger attests, so the recorded statuses describe bytes that are no longer on disk: %s"
             % (len(mismatched), ", ".join(mismatched[:5])))
    emit(True, "layer-status.json records an explicit status for all four pre-agent layers (%s), every value is OK or ERROR, each short-form twin agrees, findings-merged.json _summary.layer_status matches the ledger with zero drift and invents no key, and all %d artifacts in the ledger's attested manifest still match their recorded digest - which establishes internal consistency, not authenticity, since the manifest lives in the same tree it describes"
         % (", ".join("%s=%s" % (k, ledger[k]) for k in DETERMINISTIC_STATUS_KEYS), len(manifest)))


guard(body)
CHECK_EOF

# --- 16 ----------------------------------------------------------------------
# Every Layer 3b finding references a file:line pair present in
# sink-inventory.txt. This is what makes the sink inventory the domain of
# discourse for Layer 3b.
run 16 <<'CHECK_EOF'
def body():
    text, err = read_text("sink-inventory.txt")
    if err:
        emit(False, err)
    rows, malformed = parse_rows(text, 19)
    if malformed:
        first = malformed[0]
        emit(False, "sink-inventory.txt has %d malformed row(s), so the anchor set is not trustworthy; the first is line %d - %s"
             % (len(malformed), first[0], first[1]))
    ambiguous = unsafe({row[0] for row in rows})
    if ambiguous:
        emit(False, "sink-inventory.txt carries %d path(s) containing a colon or a control byte, so an anchor could be spoofed and the check fails closed; the first is %r"
             % (len(ambiguous), ambiguous[0]))
    anchors = {(row[0], row[1]) for row in rows}
    arr, aerr = load_array("findings-layer-3b-taint.json")
    if aerr:
        emit(False, aerr)
    unanchored = []
    malformed_records = []
    for index, record in enumerate(arr):
        if not isinstance(record, dict):
            malformed_records.append(index)
            continue
        located = record.get("file")
        line = record.get("line")
        if not isinstance(located, str) or isinstance(line, bool) or not isinstance(line, int):
            malformed_records.append(index)
            continue
        if (located, line) not in anchors:
            unanchored.append("%s:%d (index %d)" % (located, line, index))
    if malformed_records:
        emit(False, "%d Layer 3b record(s) have no string file or integer line, so their anchor cannot be checked; the first is index %d"
             % (len(malformed_records), malformed_records[0]))
    if unanchored:
        emit(False, "%d Layer 3b record(s) reference a file:line pair absent from sink-inventory.txt, which places them outside Layer 3b's domain of discourse and means they belong in Layer 1: %s"
             % (len(unanchored), "; ".join(unanchored[:3])))
    emit(True, "all %d Layer 3b records anchor to a file:line pair present in sink-inventory.txt, matched against %d distinct anchors drawn from %d format-valid rows"
         % (len(arr), len(anchors), len(rows)))


guard(body)
CHECK_EOF

# -----------------------------------------------------------------------------
# Exit with the count of failures. Zero failures means exit 0.
# -----------------------------------------------------------------------------
exit "$FAILURES"
