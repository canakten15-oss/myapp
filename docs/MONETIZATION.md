# Monetization: ads, no paywall

## Model
- Every feature is free. No subscription, no locked quality settings.
- **Ads appear only while a batch is compressing**, on the working screen, under the progress panel:
  - one **300×250 banner** slot (AdMob serves image or muted video ads in it)
  - labelled "Advertisement", fixed position, never covering the progress or the Stop button
  - set the refresh rate in the AdMob console to **60 s**, so a 10-minute batch gets about 10 impressions
- Optional **"Play something while you wait"** button on the same screen. Only if the user taps it, a full-screen ad opens. Video is switched off for this unit, so it serves playables and display ads. Compression keeps running behind it; when the user closes it they see how far it got. After closing, the button comes back (while the batch runs) for anyone who wants another one.
- **Never:** automatic full-screen ads, app-open ads, ads before a job, ads after a job, ads on the list, settings or delete screens, "watch an ad to unlock".
- Strategy: comfort over squeeze. Ads that don't annoy mean better ratings, more installs and more word of mouth. Revenue comes from volume, not from pressure per user.
- Why this is allowed: AdMob forbids 300×250 ads on "dead end" screens with no content. The working screen has real content (progress, current video, savings, time left) and a Stop button, so the user can always leave without touching the ad.
- Optional later: a one-time "remove ads" in-app purchase (~€3).

## Enable AdMob (≈ 30 min)
1. Create an AdMob account → add an iOS app → create two ad units:
   - **Banner** (for the 300×250 slot)
   - **Interstitial** (for the opt-in button) → in its settings, **untick "Video"** so only display/playable ads are served
2. In `project.yml`, uncomment the `packages:` block and the `dependencies:` block, then run `xcodegen generate`.
3. Replace the test IDs:
   - `GADApplicationIdentifier` in `project.yml` → your AdMob **app ID**
   - `AdService.bannerUnitID` → your **banner unit ID**
   - `AdService.playUnitID` → your **interstitial unit ID**
4. Add Google's `SKAdNetworkItems` list to `project.yml` (`info.properties`). Copy the current list from Google's iOS quick-start guide.
5. AdMob → *Privacy & messaging* → create a **GDPR message** (required for EU users). The app shows it via the User Messaging Platform before any ad.
6. Publish `app-ads.txt` on your developer website (the URL in App Store Connect), with the line AdMob gives you.
7. Update `PrivacyInfo.xcprivacy`: Google's SDK ships its own manifest, but your App Store privacy labels must declare what the ads collect (device ID, usage data, coarse location, ad data).

> Ad code in `AdService.swift` targets Google Mobile Ads SDK 12 / UMP 3. It is compiled only when the packages are added, and it wasn't compiled while writing this prototype. Expect small API adjustments on first build.

## More playables (optional, later)
AdMob alone can't guarantee playables. Adding mediation partners that serve many playables (AppLovin, Unity Ads, ironSource/LevelPlay) through AdMob mediation raises the share. Each needs its own SDK adapter and account.

## While testing
Always use test IDs while developing. Clicking your own live ads can get the AdMob account banned.

## Realistic expectations
- Revenue = installs × minutes spent compressing × impressions per minute (1 at 60 s refresh) × fill × eCPM. Banner eCPMs are much lower than full-screen ads, which is the price of never ruining the experience.
- Treat ads as covering costs (developer fee, domain) until install numbers prove otherwise.
- Growth levers: App Store search ("compress video", "free up iCloud storage"), Reddit/HN posts about the open-source, no-subscription angle, and a short demo video.
