class Pkf < Formula
  desc "Typed task runner with content-addressed caching, configured in Pkl"
  homepage "https://github.com/mizchi/pkfire"
  url "https://github.com/mizchi/pkfire/releases/download/pkfire@0.14.2/pkf-darwin-arm64.tar.gz"
  version "0.14.2"
  sha256 "02712bd298b06aea8f5b9a92cb9735c0da7de36e5fc09cef71bd62342bc1b998"
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
