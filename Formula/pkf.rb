class Pkf < Formula
  desc "Typed task runner with content-addressed caching, configured in Pkl"
  homepage "https://github.com/mizchi/pkfire"
  url "https://github.com/mizchi/pkfire/releases/download/pkfire@0.14.1/pkf-darwin-arm64.tar.gz"
  version "0.14.1"
  sha256 "102b556e9d86ca0cf763a694338fcd26c8c6d13d1895db6647b306561f661e13"
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
