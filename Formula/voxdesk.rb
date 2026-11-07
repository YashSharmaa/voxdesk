class Voxdesk < Formula
  desc "Local menu-bar dictation for macOS with Parakeet and Whisper on Core ML"
  homepage "https://github.com/YashSharmaa/voxdesk"
  url "https://github.com/YashSharmaa/voxdesk/archive/refs/tags/v1.0.0.tar.gz"
  sha256 "fcbf2cbb6f909155f4f0eee6a8d8acde731f21b10fd0472ef2de7ad2a24ed2fa"
  license "MIT"

  depends_on arch: :arm64
  depends_on macos: :sonoma

  def install
    # build.sh runs `swift build -c release`, assembles VoxDesk.app and signs it (Apple Development identity
    # if the keychain has one, else ad hoc). SwiftPM's own sandbox cannot nest inside Homebrew's.
    ENV["VOXDESK_SWIFT_BUILD_FLAGS"] = "--disable-sandbox"
    system "./build.sh", prefix
    bin.write_exec_script prefix/"VoxDesk.app/Contents/MacOS/VoxDesk"
    mv bin/"VoxDesk", bin/"voxdesk"
  end

  def caveats
    <<~EOS
      VoxDesk is a menu-bar app. Copy it to /Applications so macOS keeps its Microphone and
      Accessibility permissions and so launch at login works:
        cp -R "#{opt_prefix}/VoxDesk.app" /Applications/
        open /Applications/VoxDesk.app

      The first use of each engine downloads its model (Fast English about 550 MB, Multilingual 626 MB).
    EOS
  end

  test do
    assert_equal "1.0.0", shell_output("#{bin}/voxdesk --version").strip
  end
end
