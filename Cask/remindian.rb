cask "remindian" do
  version "5.30.0"
  sha256 "97328e300717b59d0d2d3ee8a2a688ac65ebd60df086e245d39668338b5f300b"

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
