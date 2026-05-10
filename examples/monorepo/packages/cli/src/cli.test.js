import { test } from "node:test";
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const here = dirname(fileURLToPath(import.meta.url));

test("CLI prints the greeting from @example/greet", () => {
  const out = execFileSync(process.execPath, [join(here, "cli.js"), "pkf"], {
    encoding: "utf8",
  });
  assert.equal(out.trim(), "hello, pkf");
});
