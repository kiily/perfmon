# Homebrew cask for Perfmon.app. app/release.sh rewrites version and sha256.
# Install: brew tap kiily/perfmon https://github.com/kiily/perfmon && brew install --cask perfmon
cask "perfmon" do
  version "1.1.0"
  sha256 "795a330b3320e43e0b45002a4692e5e782fff72391d688dfdd7597e092eb4565"

  url "https://github.com/kiily/perfmon/releases/download/v#{version}/Perfmon.dmg"
  name "Perfmon"
  desc "Menu bar system monitor: health, top apps, dev servers and their ports"
  homepage "https://github.com/kiily/perfmon"

  depends_on macos: :sonoma

  app "Perfmon.app"

  # Ad-hoc signed (no Developer ID), so drop the download quarantine or Gatekeeper refuses to open it.
  # ponytail: legacy `postflight` (brew 7 warns); move to postflight_steps once it has a quarantine step.
  postflight do
    system_command "/usr/bin/xattr", args: ["-dr", "com.apple.quarantine", "#{appdir}/Perfmon.app"]
  end

  uninstall quit: "dev.kiily.perfmon"

  zap trash: "~/Library/Application Support/Perfmon"
end
