cask "latexshot" do
  version "1.0.0"
  sha256 "53dd232a32bc03329074526e198aee063dd77b3c58ed3ba8dceaec43c735f441"

  url "https://github.com/exploringtruth/latexshot/releases/download/v#{version}/LaTeXShot-#{version}-Installer.dmg"
  name "LaTeXShot"
  desc "Capture printed equations and copy them as LaTeX"
  homepage "https://exploringtruth.github.io/latexshot/"

  depends_on arch: :arm64
  depends_on macos: :sonoma

  app "LaTeXShot.app"

  caveats <<~EOS
    LaTeXShot v#{version} is ad-hoc signed and unnotarized.
    See the first-launch instructions if macOS blocks the app.
    https://github.com/exploringtruth/latexshot#if-macos-blocks-the-app
  EOS
end
