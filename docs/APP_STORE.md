# App Store submission checklist

## Before the first upload
- [ ] Apple Developer Program active (€99/year)
- [ ] Final app name chosen and checked: App Store search, DPMA / EUIPO trademark search, domain
- [ ] `./scripts/rename.sh "Name" com.yourdomain.name`
- [ ] App icon (1024×1024, no transparency) in `Assets.xcassets/AppIcon`
- [ ] Bundle ID registered in Certificates, Identifiers & Profiles
- [ ] Privacy policy hosted at a public URL (`PRIVACY.md` on GitHub works)
- [ ] Support URL (GitHub issues page works)
- [ ] If ads are enabled: real AdMob IDs, GDPR message, `app-ads.txt`, SKAdNetwork list

## Metadata rules (common rejection reasons)
- **Never use other apps' names** in the name, subtitle, keywords, description or screenshots. Apple's guidance says not to include references to popular app names or trademarked terms in any metadata field. That rules out "alternative to …", "better than …" and similar.
- Screenshots must show the app in use, not just title art.
- Describe what the app does, not what competitors charge.
- No "iCloud" or "Apple" in the app name. Using them in the description to describe the function is fine ("frees up iCloud storage").

## Guideline 4.3 (spam) risk
"Photo/video cleaner" is a crowded category. Point out in the *Notes for App Review* field what makes this app different:
- open source (link to repo)
- 100% on-device, no account
- keeps HDR, metadata and albums, and deletes only through the iOS dialog
- no subscription

## Privacy labels (App Store Connect)
- **Without ads:** "Data Not Collected".
- **With AdMob:** declare *Identifiers (Device ID)*, *Usage Data (Product Interaction, Advertising Data)*, *Diagnostics*, *Location (Coarse)*, used for *Third-Party Advertising*, and "used to track you" = Yes if you request ATT.

## Review notes template
> The app compresses large videos in the user's photo library on-device using AVFoundation. It requires full photo library access to read originals and save smaller copies. Originals are only deleted through the standard iOS confirmation dialog. To test: record a 30-second 4K video, open the app, tap "Compress", then "Delete originals".

## Germany-specific
- A public website or landing page for the app needs an **Impressum** (§ 5 DDG) and a privacy notice.
- When you sell or show ads as a business, register a *Gewerbe* or check *Kleinunternehmer* status with a tax advisor.
