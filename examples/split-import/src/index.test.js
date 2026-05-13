import assert from "node:assert/strict";
import test from "node:test";
import { greet } from "./index.js";

test("greet", () => {
  assert.equal(greet("pkfire"), "hello, pkfire");
});
