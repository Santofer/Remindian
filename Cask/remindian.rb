cask "remindian" do
  version "5.29.0"
  sha256 "3cd2145e51d9aaeeb34bfef02eeddbb9142183f9e43bc840f68242b4cad7ac80"

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
