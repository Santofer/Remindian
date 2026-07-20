cask "remindian" do
  version "5.25.15"
  sha256 "7a24c63d9d52598fd3dc7f4adb4ed5c1063a88a7fe9e0defd112f7a3829f89cd"

  url "https://github.com/Santofer/Remindian/releases/download/v#{version}/Remindian-#{version}.dmg"
  name "Remindian"
  desc "Sync Obsidian tasks with Apple Reminders, Todoist, Asana, Linear, and more"
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
