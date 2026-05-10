import { test } from "node:test";
import assert from "node:assert/strict";
import { greet } from "./greet.js";

test("greet returns a friendly string", () => {
  assert.equal(greet("pkf"), "hello, pkf");
});

test("greet rejects empty input", () => {
  assert.throws(() => greet(""), /non-empty/);
});
