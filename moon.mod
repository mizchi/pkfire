name = "mizchi/pkf"

version = "0.16.0"

import {
  "mizchi/fswatch@0.2.1",
  "mizchi/pkl@0.7.0",
  "mizchi/x@0.5.2",
  "mizchi/zlib@0.4.8",
  "moonbitlang/async@0.22.10",
  // mizchi/pkl 0.7.0 depends on older releases that do not build with RC1.
  "moonbit-community/yaml@0.0.10",
  "moonbitlang/regexp@0.3.7",
  "moonbitlang/x@0.5.9",
}

readme = "README.md"

repository = "https://github.com/mizchi/pkfire"

license = "MIT"

keywords = [ "moonbit", "pkl", "task-runner", "build-tool" ]

description = "A Pkl-native task runner with a pure MoonBit implementation."

preferred_target = "native"
