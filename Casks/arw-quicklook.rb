# This repository doubles as a Homebrew tap:
#   brew tap raphmatt/arw-quicklook https://github.com/Raphmatt/arw-quicklook
#   brew install --cask raphmatt/arw-quicklook/arw-quicklook
# `version` and `sha256` are updated by the release workflow on every tag.
cask "arw-quicklook" do
  version "1.0.0"
  sha256 "d47253a205df42532d6110b1f63ad75da31a02670a32f4fc41e0442b004595ba"

  url "https://github.com/Raphmatt/arw-quicklook/releases/download/v#{version}/ARWQuickLook-#{version}.zip"
  name "ARW QuickLook"
  desc "Quick Look previews and Finder thumbnails for Sony ARW raw files"
  homepage "https://github.com/Raphmatt/arw-quicklook"

  # No livecheck block: the default Git strategy reads the v* tags.

  depends_on macos: :sonoma

  app "ARWQuickLook.app"

  # Ad-hoc signed, not notarized: Gatekeeper blocks it while quarantined.
  # Structured steps (sandboxed) instead of a Ruby `postflight` block, which
  # Homebrew deprecated and warns about on every brew command. The sandbox
  # can't reach Launch Services or pluginkit; macOS registers the extensions
  # when the app is opened (see caveats).
  postflight_steps do
    run "/usr/bin/xattr",
        args:           ["-dr", "com.apple.quarantine", "{{appdir}}/ARWQuickLook.app"],
        writable_paths: ["ARWQuickLook.app"],
        writable_base:  :appdir
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
    #{token} is ad-hoc signed and not notarized; this cask removes its
    quarantine flag. Open ARWQuickLook once so macOS registers the previews.
    If none appear, turn on ARWThumbnail and ARWPreview under System Settings >
    General > Login Items & Extensions > Quick Look.
  EOS
end
