cask "remindian" do
  version "5.20.0"
  sha256 "b1ce1f8665a8cdd992189ce74ced9f9773912e120680a83bf4c4c18e69a1753b"

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
