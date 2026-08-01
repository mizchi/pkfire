class Pkf < Formula
  desc "Typed task runner with content-addressed caching, configured in Pkl"
  homepage "https://github.com/mizchi/pkfire"
  url "https://github.com/mizchi/pkfire/releases/download/pkfire@0.14.0/pkf-darwin-arm64.tar.gz"
  version "0.14.0"
  sha256 "fe0706a2de5470b19ef2c079c0b7b64383c98970b60d946ebbfbee06e6d2c1ac"
  license "MIT"

  depends_on arch: :arm64
  depends_on :macos
  depends_on "pkl"

  def install
    bin.install "pkf"
  end

  test do
    assert_equal version.to_s, shell_output("#{bin}/pkf version").strip
  end
end
