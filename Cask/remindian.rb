cask "remindian" do
  version "5.27.0"
  sha256 "69a9991544d4e35a80af2ab0c3aa63410e75ccd2c8faa3fd54f8c8cb64d2834c"

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
