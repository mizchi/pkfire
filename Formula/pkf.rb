class Pkf < Formula
  desc "Typed task runner with content-addressed caching, configured in Pkl"
  homepage "https://github.com/mizchi/pkfire"
  url "https://github.com/mizchi/pkfire/releases/download/pkfire@0.16.0/pkf-darwin-arm64.tar.gz"
  version "0.16.0"
  sha256 "087b342a6597efbbcd25ab051da748c028b79f06f2f93c5fc93d8b316c2025d7"
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
