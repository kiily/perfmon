# Homebrew cask for Perfmon.app. app/release.sh rewrites version, sha256 and the asset id.
# Install: brew tap kiily/perfmon https://github.com/kiily/perfmon && brew install --cask perfmon
cask "perfmon" do
  version "0"
  sha256 "0"

  # The repo is private, so the DMG comes through the API with your GitHub token.
  url "https://api.github.com/repos/kiily/perfmon/releases/assets/0",
      header: [
        "Accept: application/octet-stream",
        "Authorization: Bearer #{ENV.fetch("HOMEBREW_GITHUB_API_TOKEN") { `gh auth token`.strip }}",
      ]
  name "Perfmon"
  desc "Menu bar system monitor: health, top apps, dev servers and their ports"
  homepage "https://github.com/kiily/perfmon"

  depends_on macos: ">= :sonoma"

  app "Perfmon.app"

  # Ad-hoc signed (no Developer ID), so drop the download quarantine or Gatekeeper refuses to open it.
  postflight do
    system_command "/usr/bin/xattr", args: ["-dr", "com.apple.quarantine", "#{appdir}/Perfmon.app"]
  end

  uninstall quit: "dev.kiily.perfmon"

  zap trash: "~/Library/Application Support/Perfmon"
end
