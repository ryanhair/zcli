class Zcli < Formula
  desc "Build beautiful command-line interfaces with Zig"
  homepage "https://github.com/ryanhair/zcli"
  version "0.1.0"
  license "MIT"

  on_macos do
    if Hardware::CPU.arm?
      url "https://github.com/ryanhair/zcli/releases/download/v#{version}/zcli-aarch64-macos"
      sha256 "REPLACE_WITH_AARCH64_MACOS_SHA256"
    else
      url "https://github.com/ryanhair/zcli/releases/download/v#{version}/zcli-x86_64-macos"
      sha256 "REPLACE_WITH_X86_64_MACOS_SHA256"
    end
  end

  on_linux do
    if Hardware::CPU.arm?
      url "https://github.com/ryanhair/zcli/releases/download/v#{version}/zcli-aarch64-linux"
      sha256 "REPLACE_WITH_AARCH64_LINUX_SHA256"
    else
      url "https://github.com/ryanhair/zcli/releases/download/v#{version}/zcli-x86_64-linux"
      sha256 "REPLACE_WITH_X86_64_LINUX_SHA256"
    end
  end

  def install
    bin.install Dir["zcli-*"].first => "zcli"
  end

  test do
    assert_match "zcli v#{version}", shell_output("#{bin}/zcli --version")
  end
end
