cask "remindian" do
  version "5.16.0"
  sha256 "a4dbb4c8442f619372b288d4cf97faf9d6a9e0fe278a89f7c36a4d8992fabc29"

  url "https://github.com/Santofer/Remindian/releases/download/v#{version}/Remindian-v#{version}.dmg"
  name "Remindian"
  desc "Sync Obsidian tasks with Apple Reminders, Todoist, Asana, Linear, and more"
  homepage "https://github.com/Santofer/Remindian"

  auto_updates true
  depends_on macos: ">= :ventura"

  app "Remindian.app"

  zap trash: [
    "~/Library/Application Support/Remindian",
    "~/Library/Containers/com.remindian.app",
    "~/Library/Preferences/com.remindian.app.plist",
  ]
end
