#!/usr/bin/env python3
"""Exercise MCP against a separate QA app copy, including real editor and PDF operations."""

import json
import pathlib
import select
import subprocess
import sys


class Client:
    def __init__(self, app, read_root, write_root):
        binary = pathlib.Path(app) / "Contents/MacOS/Inkline"
        command = [str(binary), "mcp", "--automation-read-root", str(read_root)]
        if write_root is not None:
            command += ["--automation-write-root", str(write_root)]
        self.process = subprocess.Popen(
            command,
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            text=True, bufsize=1,
        )
        self.counter = 0
        value = self.request("initialize", {
            "protocolVersion": "2025-11-25", "capabilities": {},
            "clientInfo": {"name": "inkline-regression-test", "version": "1"},
        })
        assert value["protocolVersion"] == "2025-11-25", value
        self.notify("notifications/initialized")

    def notify(self, method):
        self.process.stdin.write(json.dumps({"jsonrpc": "2.0", "method": method}) + "\n")
        self.process.stdin.flush()

    def request(self, method, params=None):
        self.counter += 1
        message = {"jsonrpc": "2.0", "id": self.counter, "method": method}
        if params is not None:
            message["params"] = params
        self.process.stdin.write(json.dumps(message) + "\n")
        self.process.stdin.flush()
        ready, _, _ = select.select([self.process.stdout], [], [], 58)
        if not ready:
            raise TimeoutError("No MCP response for " + method)
        line = self.process.stdout.readline()
        if not line:
            raise RuntimeError(self.process.stderr.read())
        response = json.loads(line)
        assert response["id"] == self.counter, response
        if "error" in response:
            raise RuntimeError(response["error"])
        return response["result"]

    def call(self, name, expect_error=False, **arguments):
        result = self.request("tools/call", {"name": name, "arguments": arguments})
        assert bool(result.get("isError")) == expect_error, result
        return result if expect_error else result["structuredContent"]

    def close(self):
        self.process.stdin.close()
        assert self.process.wait(timeout=5) == 0


def exercise(app, folder):
    root = folder / "shared"
    root.mkdir()
    outside = folder / "outside.md"
    outside.write_text("# Outside\n")
    client = Client(app, root, root)
    try:
        tools = client.request("tools/list")["tools"]
        assert len(tools) >= 12
        document = client.call("create_document", format="markdown", source="# MCP test\n\n한글 ✓\n")
        doc_id = document["document_id"]
        first = client.call("read_document", document_id=doc_id)
        assert first["source"] == "# MCP test\n\n한글 ✓\n"
        assert first["modified"]

        client.call("close_document", document_id=doc_id, expect_error=True)
        changed = client.call(
            "edit_document", document_id=doc_id, expected_revision=first["revision"],
            old_text="MCP test", new_text="Connected editor",
        )
        assert changed["revision"] != first["revision"]
        client.call("replace_document", document_id=doc_id, expected_revision=first["revision"],
                    source="stale write", expect_error=True)
        current = client.call("read_document", document_id=doc_id)
        assert current["source"].startswith("# Connected editor")
        client.call("edit_document", document_id=doc_id, expected_revision=current["revision"],
                    old_text="missing", new_text="", expect_error=True)
        overlapping = client.call("create_document", format="markdown", source="aaa")
        client.call("edit_document", document_id=overlapping["document_id"], expected_revision=overlapping["revision"],
                    old_text="aa", new_text="b", expect_error=True)
        client.call("save_document", document_id=overlapping["document_id"], path=str(root / "overlap.md"))
        client.call("close_document", document_id=overlapping["document_id"])

        saved = client.call("save_document", document_id=doc_id, path=str(root / "note.md"))
        assert not saved["modified"], saved
        assert (root / "note.md").read_text() == current["source"]
        readonly = Client(app, root, None)
        try:
            readable = readonly.call("read_document", document_id=doc_id)
            readonly.call("replace_document", document_id=doc_id, expected_revision=readable["revision"],
                          source="read-only write", expect_error=True)
        finally:
            readonly.close()
        client.call("save_document", document_id=doc_id, path=str(outside), overwrite=True, expect_error=True)
        assert outside.read_text() == "# Outside\n"
        client.call("open_document", path=str(outside), expect_error=True)

        alias = root / "outside-link"
        alias.symlink_to(folder, target_is_directory=True)
        client.call("open_document", path=str(alias / "outside.md"), expect_error=True)
        broken = root / "broken.md"
        broken.symlink_to(folder / "missing.md")
        client.call("save_document", document_id=doc_id, path=str(broken), overwrite=True, expect_error=True)

        uri = current["resource_uri"]
        resources = client.request("resources/list")["resources"]
        assert any(resource["uri"] == uri for resource in resources)
        content = client.request("resources/read", {"uri": uri})["contents"][0]
        assert content["text"] == current["source"]

        client.call("set_view", document_id=doc_id, view="preview")
        client.call("export_pdf", document_id=doc_id, expected_revision=current["revision"],
                    path=str(root / "note.pdf"))
        assert (root / "note.pdf").read_bytes().startswith(b"%PDF")
        client.call("export_pdf", document_id=doc_id, expected_revision=current["revision"],
                    path=str(root / "note.pdf"), expect_error=True)
        client.call("close_document", document_id=doc_id)
        reopened = client.call("open_document", path=str(root / "note.md"))
        assert client.call("read_document", document_id=reopened["document_id"])["source"] == current["source"]
        copy = client.call("set_format", document_id=reopened["document_id"], format="html")
        assert copy["document_id"] != reopened["document_id"]
        assert (root / "note.md").read_text() == current["source"]
        client.call("replace_document", document_id=copy["document_id"], expected_revision=copy["revision"],
                    source="<h1>HTML over MCP</h1><p>Rendered output</p>")
        html = client.call("read_document", document_id=copy["document_id"])
        client.call("export_pdf", document_id=html["document_id"], expected_revision=html["revision"],
                    path=str(root / "html.pdf"))
        client.call("save_document", document_id=html["document_id"], path=str(root / "page.html"))
        client.call("close_document", document_id=html["document_id"])
        client.call("close_document", document_id=reopened["document_id"])
        latex = client.call("create_document", format="latex")
        compiled = client.call("compile_latex", document_id=latex["document_id"])
        assert compiled["success"], compiled
        client.call("export_pdf", document_id=latex["document_id"], expected_revision=latex["revision"],
                    path=str(root / "latex.pdf"))
        assert (root / "latex.pdf").read_bytes().startswith(b"%PDF")
        client.call("save_document", document_id=latex["document_id"], path=str(root / "main.tex"))
        client.call("close_document", document_id=latex["document_id"])
        print("MCP lifecycle, source edits, stale revisions, resources, native save/reopen, format copies, and PDF exports passed.", flush=True)
        print("File scope, read-only access, overlapping matches, symlink escapes, overwrite protection, and unsaved-close checks passed.", flush=True)
        print("Native LaTeX compilation and PDF export passed.", flush=True)
    finally:
        client.close()


if __name__ == "__main__":
    if len(sys.argv) != 3:
        raise SystemExit("Usage: test-mcp.py /path/to/QA.app /path/to/existing/temporary-folder")
    exercise(pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2]))
