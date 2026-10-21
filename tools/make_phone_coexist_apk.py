"""Package the GitHub Actions trial for isolated physical-device testing."""
from __future__ import annotations

import importlib.util
from pathlib import Path

BASE = Path(__file__).resolve().parents[1]
SOURCE = BASE / "dist/run-39519164021/Kazumi-2.3.9-ui-compat-trial.apk"
EXPECTED_SHA256 = (
    "eaeb7e370ec17446b6fed66000626fa45af8f887f073ef35063b877533caf445"
)
PARSER = Path(r"C:\bug335\reverse\Kazumi\20261016-114526\reports\native\make_coexist_apk.py")
OUTPUT = BASE / "dist/phone-test/Kazumi-2.3.9-kazumj-unsigned.apk"
REPORT = BASE / "reports/kazumj-package-edits-20261021.json"

spec = importlib.util.spec_from_file_location("coexist_parser", PARSER)
if spec is None or spec.loader is None:
    raise RuntimeError(f"Cannot load reviewed package parser: {PARSER}")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
module.SOURCE_SHA256 = EXPECTED_SHA256
module.main(SOURCE, OUTPUT, REPORT)

