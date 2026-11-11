cask "remindian" do
  version "5.34.1"
  sha256 "2c1243776f8de8c31e1dc7a2967b6d0e93f8885a4c400c103528839ebe25410d"

  url "https://github.com/Santofer/Remindian/releases/download/v#{version}/Remindian-#{version}.dmg"
  name "Remindian"
  desc "Sync Obsidian tasks with Apple Reminders, Things 3, Todoist, and TickTick"
  homepage "https://github.com/Santofer/Remindian"

  auto_updates true
  depends_on macos: :ventura

  app "Remindian.app"

  zap trash: [
    "~/Library/Application Support/Remindian",
    "~/Library/Containers/com.remindian.app",
    "~/Library/Preferences/com.remindian.app.plist",
  ]
end
