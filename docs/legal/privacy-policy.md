<!--
DRAFT. Not published. Before hosting at https://roll.delavalom.com/privacy:
- replace {{CONTACT_EMAIL}}, {{EFFECTIVE_DATE}} and {{DEVELOPER_NAME}} (the seller name on the App Store);
- re-check every statement against the shipping build (the source notes at the end of this file say where each
  one comes from), then delete the notes.
-->

# Roll Privacy Policy

Effective date: {{EFFECTIVE_DATE}}

Roll is a photo cleanup app for iPhone made by {{DEVELOPER_NAME}} ("we"). This policy explains what happens to your
information when you use Roll. The short version: your photos are analyzed on your iPhone and are never uploaded.
We don't run analytics, we don't track you, and we don't have accounts.

## Your photos stay on your iPhone

Roll asks for access to your photo library so it can find things you may want to delete, move to an album or
shrink ("squish"). All of that analysis runs on your device:

- Roll reads your photos and videos through Apple's Photos framework and analyzes them on your iPhone, using an AI
  model that runs on the device and Apple's on-device Vision and Sensitive Content Analysis frameworks.
- No photos, videos, thumbnails, embeddings (the numbers the AI model computes from a photo), or the descriptions
  you type are sent to us or to anyone else.
- If you use iCloud Photos, Roll may ask Photos to download the full-size original of an item from your own iCloud
  Photos library so it can be analyzed or squished. That download is between your device and Apple, as part of
  iCloud Photos.

## What Roll stores on your iPhone

Roll keeps its working data in the app's own private storage on your iPhone:

- an index of your library: item identifiers, dates, sizes and types, and the results of the on-device analysis
  (for example blur and quality scores, image fingerprints used to find duplicates, and AI embeddings);
- your swipefiles: their names, the descriptions you type, your swipe decisions, and small models trained on your
  device from those decisions;
- a record of squishes in progress, so an interrupted squish can be finished or undone;
- a count of the cleanups you have used on the free tier;
- the downloaded AI model.

The AI embeddings and the AI model are excluded from iCloud and computer backups. The rest of the index (including
the image fingerprints, your swipefiles and the descriptions you typed) is stored in a database that is not
excluded, so if you back up your iPhone to iCloud or to a computer, it is included in that backup, which is stored
by Apple or on your computer and not by us.

Everything Roll stores is deleted when you delete the app.

## Network connections Roll makes

Roll connects to the internet for two things only.

**Downloading the AI model.** The first time Roll needs its AI model, it downloads the model files from Hugging Face
(huggingface.co), which may serve them through its content delivery network. It downloads them again when an app update
brings a new version of the model. Like any web server, Hugging Face sees
your device's IP address and the request (which files are being downloaded, plus standard technical details such as
the app name and iOS version that iOS adds to web requests). Roll sends nothing about you or your photos in that
request. Hugging Face's handling of this information is covered by its own privacy policy.

**Subscriptions.** Roll uses RevenueCat to handle subscriptions, and Apple processes all payments. When the app
starts, shows the paywall, or you buy or restore a subscription, Roll's purchase component sends to RevenueCat:

- a random, anonymous app user ID created on your device (it isn't linked to your name, email or Apple Account by us);
- your purchase and subscription details from Apple (transactions and receipts);
- technical information: the identifier for vendor (an ID iOS gives each developer's apps on your device), device
  model, iOS version, app version, preferred languages, App Store country, and your IP address as part of the
  connection.

RevenueCat uses this to tell Roll whether you have Roll Pro. Apple handles the payment itself under Apple's own
privacy policy; we never see your payment details. RevenueCat's handling is covered by its privacy policy.

## What we don't do

- No accounts. You never sign up or log in.
- No analytics, advertising or tracking SDKs. We don't track you across apps or websites, and we don't use the
  advertising identifier.
- No selling or sharing of your information with third parties, other than the service providers above
  (Hugging Face for the model download, RevenueCat and Apple for subscriptions) doing the jobs described.

## Face ID

If you lock your Private swipefile, Roll asks iOS to check your Face ID or passcode. iOS does the check and only
tells Roll whether it succeeded. Roll never receives your face data.

## Children

Roll is not directed at children under 13, and we don't knowingly collect personal information from children.

## Your choices

- You can change or remove Roll's photo access at any time in Settings > Privacy & Security > Photos.
- You can manage or cancel a subscription in Settings > [your name] > Subscriptions.
- You can delete everything Roll stores on your iPhone by deleting the app.
- We don't hold your photos or an account for you. To ask about the subscription records RevenueCat keeps for
  Roll, or to have them deleted, contact us at the address below.

## Changes

If we change this policy, we will update it here and change the effective date above.

## Contact

Questions about this policy: {{CONTACT_EMAIL}}

<!--
Source notes (for maintainers; delete when publishing):
- On-device analysis, no photo upload: AGENTS.md rule "No network except the model download (ModelInstall's
  BackgroundTransport) and RevenueCat. No analytics SDKs."; App/PrivacyInfo.xcprivacy declares no tracking and no collected data.
- iCloud originals: PHImageRequestOptions.isNetworkAccessAllowed in Library/PhotoLibrary.swift and
  Squish/ReplaceFlow.swift.
- Storage: Store/Database.swift (Application Support/Roll/roll.sqlite, NOT excluded from backup; tables asset with
  featurePrint, swipefile with prompts and classifier, decision, quota, squishJournal, squishRefusal).
  Store/VectorStore.swift (Application Support/Roll/Index, isExcludedFromBackup = true).
  ModelInstall/ModelFolders.swift (Application Support/RollModel: the downloaded archive and its files while it
  installs, then only a small marker; isExcludedFromBackup = true) and EmbeddingGemma ModelStore/Installer (Application
  Support/EmbeddingGemma, the compiled model, isExcludedFromBackup = true).
  Squish scratch files are in the temporary directory.
- Hugging Face: ModelInstall/PublishedModel.swift (huggingface.co/<repo>/resolve/<commit>/manifest.json and one .aar),
  background URLSession (BackgroundTransport.swift) with default headers; Wi-Fi only unless the person chooses mobile
  data. A new model revision in an app update downloads again.
- RevenueCat: App/Entitlements.swift (Purchases.configure with the public key, no custom user ID, no attributes).
  purchases-ios 5.x HTTPClient default headers include X-Apple-Device-Identifier (identifierForVendor), device
  model, OS and app version, preferred locales and storefront.
- Face ID: LocalAuthentication in App/Features/Swipefiles/SwipefileListModel.swift.
-->
