"""Генерирует ExportOptions.plist для xcodebuild -exportArchive из переменных окружения."""
import os, plistlib

env = os.environ.get
method = env("EXPORT_METHOD", "development")
team = env("TEAM_ID", "")
app_id = env("APP_ID", "ru.dnevnik.app")
profile = env("PROFILE_NAME", "")

opts = {
    "method": method,
    "teamID": team,
    "signingStyle": "manual" if profile else "automatic",
    "stripSwiftSymbols": True,
    "destination": "export",
    "manageAppVersionAndBuildNumber": False,
}
if method in ("app-store", "enterprise"):
    opts["uploadSymbols"] = True
if profile:
    opts["provisioningProfiles"] = {app_id: profile}

with open("ExportOptions.plist", "wb") as fh:
    plistlib.dump(opts, fh)

print("ExportOptions.plist:", opts)
