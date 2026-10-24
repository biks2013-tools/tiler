cask "tiler" do
  version "0.8.3"
  sha256 "aef674c4d13a59f56d61afc55a9be20947bb790be82f461dc4849e65a23ffb57"

  url "https://github.com/biks2013-tools/tiler/releases/download/v#{version}/Tiler-#{version}.zip"
  name "Tiler"
  desc "Menu bar tiling window manager for one desktop at a time"
  homepage "https://github.com/biks2013-tools/tiler"

  depends_on macos: :sonoma

  app "Tiler.app"

  postflight_steps do
    run "/usr/bin/osascript",
        args: [
          "-e",
          'display notification "Open Tiler and allow Accessibility when asked." with title "Tiler installed"',
        ]
  end

  uninstall quit: "com.giorgosmarinos.tiler"

  zap trash: "~/Library/Application Support/Tiler"

  caveats <<~EOS
    First launch: open Tiler (menu bar icon, no Dock icon) and allow Accessibility:
      System Settings > Privacy & Security > Accessibility > enable Tiler
    It is the only permission Tiler needs.

    Tile a desktop: menu bar icon > Tile This Desktop, or Ctrl+Cmd+P.
    Only that desktop on that display is tiled; everything else is left alone.

    Show every shortcut: Ctrl+Cmd+/   Settings: menu bar icon > Settings...
    Move or resize any untiled window with the keyboard: Ctrl+Cmd+M, then arrows
    (Shift resizes, Option = fine, C centre, M fill, Return done).
    Move the focused window to the previous / next desktop: Ctrl+Cmd+, / Ctrl+Cmd+.
    (keep Mission Control "Move left/right a space" shortcuts turned on).
    Focus follows mouse (optional): menu bar icon > Focus Follows Mouse.
    Upgrading: Settings > General > Add Missing Settings (adds new settings only).
    Launch at login: Settings > General.

    Decks: https://biks2013-tools.github.io/tiler/
  EOS
end
