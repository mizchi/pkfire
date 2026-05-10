#!/usr/bin/env node
import { greet } from "@example/greet";

const name = process.argv[2] ?? "world";
console.log(greet(name));
