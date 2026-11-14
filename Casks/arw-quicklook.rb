# This repository doubles as a Homebrew tap:
#   brew tap raphmatt/arw-quicklook https://github.com/Raphmatt/arw-quicklook
#   brew install --cask raphmatt/arw-quicklook/arw-quicklook
# `version` and `sha256` are updated by the release workflow on every tag.
cask "arw-quicklook" do
  version "1.0.0"
  sha256 :no_check # replaced with the real checksum by the release workflow

  url "https://github.com/Raphmatt/arw-quicklook/releases/download/v#{version}/ARWQuickLook-#{version}.zip"
  name "ARW QuickLook"
  desc "Quick Look previews and Finder thumbnails for Sony ARW raw files"
  homepage "https://github.com/Raphmatt/arw-quicklook"

  # No livecheck block: the default Git strategy reads the v* tags.

  depends_on macos: :sonoma

  app "ARWQuickLook.app"

  # Legacy Ruby block on purpose: `postflight_steps` runs in Homebrew's sandbox,
  # which blocks LaunchServices and pluginkit, so it cannot register or enable
  # the extensions. Deprecated (one warning per install) and only kept for
  # third-party taps "temporarily"; it errors when HOMEBREW_DEVELOPER is set.
  postflight do
    app = "#{appdir}/ARWQuickLook.app"
    # Ad-hoc signed, not notarized: Gatekeeper blocks it while quarantined.
    system_command "/usr/bin/xattr",
                   args: ["-dr", "com.apple.quarantine", app]
    system_command "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister",
                   args: ["-f", app]
    %w[thumbnail preview].each do |ext|
      appex = "#{app}/Contents/PlugIns/ARW#{ext.capitalize}.appex"
      system_command "/usr/bin/pluginkit", args: ["-a", appex]
      system_command "/usr/bin/pluginkit", args: ["-e", "use", "-i", "io.github.raphmatt.arwquicklook.#{ext}"]
    end
    system_command "/usr/bin/qlmanage", args: ["-r"]
  end

  uninstall quit: "io.github.raphmatt.arwquicklook"

  zap trash: [
    "~/Library/Application Scripts/io.github.raphmatt.arwquicklook*",
    "~/Library/Application Support/ARWQuickLook",
    "~/Library/Containers/io.github.raphmatt.arwquicklook",
    "~/Library/Containers/io.github.raphmatt.arwquicklook.preview",
    "~/Library/Containers/io.github.raphmatt.arwquicklook.thumbnail",
  ]

  caveats <<~EOS
    #{token} is ad-hoc signed and not notarized. This cask removes its quarantine
    flag. If no previews appear, turn on ARWThumbnail and ARWPreview under
    System Settings > General > Login Items & Extensions > Quick Look.
  EOS
end
