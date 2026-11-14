# Homebrew cask for this repository used as a tap:
#   brew tap raphmatt/arw-quicklook https://github.com/Raphmatt/arw-quicklook
#   brew install --cask arw-quicklook
# `version` and `sha256` are updated by the release workflow on every tag.
cask "arw-quicklook" do
  version "1.0.0"
  sha256 :no_check

  url "https://github.com/Raphmatt/arw-quicklook/releases/download/v#{version}/ARWQuickLook-#{version}.zip"
  name "ARW QuickLook"
  desc "Fast Quick Look previews and Finder thumbnails for Sony ARW raw files"
  homepage "https://github.com/Raphmatt/arw-quicklook"

  depends_on macos: ">= :sonoma"

  app "ARWQuickLook.app"

  postflight do
    app = "#{appdir}/ARWQuickLook.app"
    # The build is ad-hoc signed, not notarized: without this Gatekeeper
    # blocks the app and Quick Look won't load its extensions.
    system_command "/usr/bin/xattr", args: ["-dr", "com.apple.quarantine", app]
    system_command "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister",
                   args: ["-f", app]
    %w[Thumbnail Preview].each do |ext|
      system_command "/usr/bin/pluginkit", args: ["-a", "#{app}/Contents/PlugIns/ARW#{ext}.appex"]
      system_command "/usr/bin/pluginkit", args: ["-e", "use", "-i", "io.github.raphmatt.arwquicklook.#{ext.downcase}"]
    end
    system_command "/usr/bin/qlmanage", args: ["-r"]
  end

  uninstall quit: "io.github.raphmatt.arwquicklook"

  zap trash: "~/Library/Application Support/ARWQuickLook"

  caveats <<~EOS
    ARW QuickLook is ad-hoc signed, not notarized by Apple. This cask removes
    the quarantine flag so macOS lets it run. If previews don't appear, check
    that both extensions are on:
      pluginkit -mAvv | grep -i -A1 "arwquicklook\\."
  EOS
end
