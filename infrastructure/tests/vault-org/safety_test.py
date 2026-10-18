#!/usr/bin/env python3
"""Security regressions using invented in-memory bw records; never opens a vault or launches a CLI."""
import copy
import importlib.util
import json
import pathlib
import sys
import types
import unittest

SOURCE = pathlib.Path(sys.argv.pop(1)) if len(sys.argv) > 1 else pathlib.Path(__file__).resolve().parents[3] / ".config/hypr/scripts/vault-org.py"
spec = importlib.util.spec_from_file_location("vault_org_safety", SOURCE)
v = importlib.util.module_from_spec(spec)
v.__file__ = str(pathlib.Path(__file__).resolve().parents[3] / ".config/hypr/scripts/vault-org.py")
exec(compile(SOURCE.read_text(), str(SOURCE), "exec"), v.__dict__)
v.local_users = lambda: []


def login():
    return {"id": "discard", "name": "Example login", "type": 1, "folderId": "ordinary", "revisionDate": "2026-01-01",
            "login": {"username": "example-user", "password": "invented-password", "totp": None,
                      "uris": [{"uri": "https://example.test/signin", "match": None}]},
            "notes": None, "fields": [], "passwordHistory": [], "attachments": [], "reprompt": 0}


class Journal:
    def __init__(self, seen=()):
        self.done = set(seen)
        self.lines = []

    def seen(self, step, ident):
        return (step, ident) in self.done

    def log(self, *args):
        self.lines.append(args)


class BW:
    def __init__(self, x, keep, folders=None):
        self.items = {i["id"]: copy.deepcopy(i) for i in (x, keep)}
        self.folders = folders or [{"id": "ordinary", "name": "Private"}, {"id": "shared", "name": "Shared/Example"}]
        self.writes = []

    def b64(self, data):
        return data

    def first_line(self, data):
        return data.splitlines()[0] if data else ""

    def folder_id(self, name, create=False):
        found = next((f["id"] for f in self.folders if f["name"] == name), None)
        if found or not create:
            return found
        ident = "new-" + str(len(self.folders))
        self.folders.append({"id": ident, "name": name})
        return ident

    def bw(self, *args, stdin=None):
        if args[:2] == ("list", "folders"):
            data = self.folders
        elif args[:2] == ("get", "item"):
            data = self.items.get(args[2])
        elif args[:2] == ("list", "items"):
            data = [i for i in self.items.values() if i.get("folderId") == args[3]]
        else:
            self.writes.append(args)
            data = stdin or {}
        return types.SimpleNamespace(returncode=0, stdout=json.dumps(data), stderr="")


class Preservation(unittest.TestCase):
    def check_pair(self, x, keep):
        bw = BW(x, keep)
        audit = v.build_audit([x, keep], 0, bw.folders, b"invented-test-key")
        rows = v.propose(audit, [])
        proposal = next(r for r in rows if r.id == "discard")
        with self.subTest(phase="proposal"):
            self.assertFalse(proposal.target.startswith("trash-duplicate-of:"), proposal.note)
        for note in ("identical", "manual"):
            row = v.Row("item", "discard", x["name"], "Private", "trash-duplicate-of:keep", "-", note)
            with self.subTest(phase="apply", note=note):
                bw.writes.clear()
                v.Applier(bw, [row], Journal(), audit).trash()
                self.assertEqual([], bw.writes, "manual marker must never bypass preservation")

    def test_unique_data_proposal_and_apply(self):
        changes = {
            "passkey": lambda x: x["login"].update(fido2Credentials=[{"credentialId": "invented-id", "keyValue": "invented-key"}]),
            "history": lambda x: x.update(passwordHistory=[{"password": "invented-old-password", "lastUsedDate": "2025-01-01"}]),
            "uri_path": lambda x: x["login"]["uris"][0].update(uri="https://example.test/other"),
            "uri_match": lambda x: x["login"]["uris"][0].update(match=3),
            "uri_www": lambda x: x["login"]["uris"][0].update(uri="https://www.example.test"),
            "uri_port": lambda x: x["login"]["uris"][0].update(uri="example.test:8443"),
            "username_case": lambda x: x["login"].update(username="Example-User"),
            "field_type": lambda x: x["fields"][0].update(type=1),
            "field_link": lambda x: x["fields"][0].update(linkedId=100),
            "attachment": lambda x: x["attachments"][0].update(id="different-content-id"),
            "unknown_top": lambda x: x.update(futureCredential={"value": "invented-value"}),
            "unknown_login": lambda x: x["login"].update(futureKey="invented-value"),
            "unknown_field": lambda x: x["fields"][0].update(futureType=7),
            "unknown_uri": lambda x: x["login"]["uris"][0].update(futureMatch=8),
            "unknown_history": lambda x: x.update(passwordHistory=[{"password": "invented", "futureDate": "2026"}]),
            "policy": lambda x: x.update(reprompt=1),
        }
        for name, change in changes.items():
            with self.subTest(name=name):
                keep = login(); keep.update(id="keep", revisionDate="2026-10-01")
                if name.startswith("field_") or name == "unknown_field":
                    keep["fields"] = [{"name": "Example", "value": "same", "type": 0, "linkedId": None}]
                if name == "attachment":
                    keep["attachments"] = [{"id": "first-content-id", "fileName": "example.txt", "size": "10"}]
                x = copy.deepcopy(keep); x.update(id="discard", revisionDate="2026-01-01")
                change(x)
                self.check_pair(x, keep)

    def test_type_specific_data(self):
        variants = [(4, "identity", "address1"), (4, "identity", "email"), (4, "identity", "phone"),
                    (3, "card", "brand"), (3, "card", "cardholderName"),
                    (5, "sshKey", "publicKey"), (5, "sshKey", "keyFingerprint"), (2, "secureNote", "type")]
        for typ, field, key in variants:
            with self.subTest(type=typ, field=key):
                keep = login(); keep.pop("login"); keep.update(id="keep", type=typ, revisionDate="2026-10-01", **{field: {key: "one"}})
                x = copy.deepcopy(keep); x.update(id="discard", revisionDate="2026-01-01"); x[field][key] = "two"
                self.check_pair(x, keep)

    def test_identical_and_missing_password(self):
        for missing in (False, True):
            keep = login(); keep.update(id="keep", revisionDate="2026-10-01")
            x = copy.deepcopy(keep); x.update(id="discard", revisionDate="2026-01-01")
            if missing:
                x["login"]["password"] = None
            bw = BW(x, keep)
            audit = v.build_audit([x, keep], 0, bw.folders, b"invented-key")
            row = next(r for r in v.propose(audit, []) if r.id == "discard")
            self.assertTrue(row.target.startswith("trash-duplicate-of:"))
            v.Applier(bw, [row], Journal(), audit).trash()
            self.assertEqual([("delete", "item", "discard")], bw.writes)


if __name__ == "__main__":
    unittest.main()
