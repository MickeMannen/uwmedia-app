# Changelog

All notable changes to the UWMedia app are listed here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions are the
git tags.

## [0.1.3] - 2026-11-22

### Added

- Color: with several photos picked, the slider under the live preview
  steps through them, so each photo can be looked at with its color
  correction and overlays before the run. It names the photo shown,
  "DSC08854.JPG · 3 of 679".
- Color, on a computer: under the output the page says how much room
  the results will take, about, and how much is free on that disk. When
  they will not fit it warns, and Start asks before going on. A run
  that fills the disk anyway stops with a plain message.

### Changed

- Color: the progress of a run shows the whole run first (one bar, the
  files done and the time left) and then the one file in progress,
  instead of two bars and a line naming every file being worked on.
- Color: the time left of a run is worked out from the sizes of the
  files, the pace of the files just finished and how far the videos in
  progress really are. Before, every file counted the same, and with
  videos of different lengths the figure stayed far too high.
- Color: a photo named by its date ends in the hundredths of a second
  instead of the milliseconds ("20261107_105639_23.jpg", before
  "…_233.jpg"). Two files of a run that would still get the same name
  are numbered "_1", "_2", and one never writes over the other.
- Color and Overlay Generator, on a computer: with several files picked
  the source line shows how many there are and their folder ("679 files
  in ~/DivingMedia/…/photo") instead of listing the first names.
- macOS: the download is a disk image (.dmg) instead of a zip: open it
  and drag UWMedia to Applications. The image is signed and notarised
  as the app is.

### Fixed

- Color, on a computer: the window no longer stands still for seconds
  when a run of many photos starts; the photos are written in the
  background.

## [0.1.2] - 2026-11-22

### Added

- Color, on a computer: "Before and after" writes the original and the
  color corrected picture in one, split left and right, above and below
  or diagonally, with the overlays on both sides. A video's comparison
  is ten seconds at most; the file is named "… compare".
- Color, on a computer: a photo can be written as a four-second wipe
  video in which an edge moves across the still photo and uncovers the
  color corrected picture.

## [0.1.1] - 2026-11-21

### Changed

- macOS: the download is signed with a Developer ID and notarised by
  Apple, so it opens without a Gatekeeper warning.
- Android: Color analyses a video at the exact frames and reads their
  colours as the computers and the iPhone do, so a phone's correction
  of a clip comes much closer to the desktop's.

## [0.1.0] - 2026-11-21

### Added

- About: UWMedia's own MIT licence is in the app, first in "Open-source
  licenses", instead of a pointer to the repository.
- Dive Logs, on a computer: drop log files, a Garmin zip or a whole
  folder on the page to import them, as with "Import logs…".
- Overlay Designer and Dive Profile Builder: "The imported logs" opens
  the logs kept on the Dive Logs page, so a log need not be looked for
  again on disk.
- Color: drag a watermark on the preview to move it for this session's
  runs, for example off a diver's face; "Put back" returns it to the
  place set under Settings, which is not changed.
- Overlay Designer, on a computer: checkout mode for working on the
  built-in templates. A development build started with
  `--dart-define=UWMEDIA_CHECKOUT=true` from a checkout of the source
  saves a built-in page straight into the source's templates. An
  installed app is unchanged.
- Color: write only a part of a video, on a computer too. With one
  video selected, drag the two ends of "Part to write" under the preview
  to where the part starts and ends (the preview follows), for the ten
  seconds worth sharing of a long video. When an end is let go the
  slider shows the part with 5 seconds before and after it, so it can be
  set finely; drag an end into those seconds to make the part longer.
  The slider above it goes over the part alone, so a frame is easy to
  find.
- Color: zoom in on a part of the picture, for a photo or a video, for
  landscape and for portrait. With one file selected, choose the shape
  above the preview ("As shot", "Portrait 9:16", "Landscape 16:9",
  "Square 1:1" or "Portrait with bars"), then zoom in on the preview
  itself with two fingers (on a computer: the slider under it, or a
  pinch on the trackpad) and drag the picture to the part to keep. What
  the preview shows is what is written. A landscape video can so be cut out of an upright one. The overlays and
  the watermark are laid on the part kept. A run of several files
  writes each as it is.
- Color: the app's icon moves on the preview while a photo or a video is
  being read, so a slow first picture does not look like nothing
  happened.
- About: "Report a problem" makes a report of the app's version, the
  system and what the last runs said, to copy (or save, on a computer)
  and send when something goes wrong. Nothing is sent by the app itself.
- Windows, macOS and Linux downloads: FFmpeg and ExifTool come inside
  the app, so there is nothing else to install. The About page says
  which versions.
- Settings (Mac): "Video engine" chooses what writes the videos of the
  Color and Resize pages and of the Overlay Generator (ProRes 4444 with
  transparency, HEVC): FFmpeg as before, or macOS's own engine, which
  is faster and leaves the Mac free for other work. FFmpeg stays the
  choice until you change it. macOS's engine reads no MKV or AVI.
- iPhone, iPad and macOS's engine: a result keeps its camera's maker and
  model also when the camera wrote them in a place of its own (Sony,
  DJI).
- iPhone, iPad and macOS's engine: a 10-bit video stays 10-bit (HEVC
  Main 10) when it is colour corrected, overlaid or resized, where it
  came out 8-bit before. Copies for sharing are 8-bit H.264 as before.
- Color and Resize (phones and tablets): "Save to" takes an album of
  your choosing ("An album in Photos…"): type its name, or on the iPhone
  tap one of your albums. It is remembered for both pages and the next
  start. "A new album in Photos" is no longer a choice there.
- Watermarks: drag a watermark to where you want it, on a sample picture
  of your own, instead of choosing one of nine places (the list of places
  is gone). Put a finger anywhere on the picture and the mark follows; it
  still snaps to the edges and the middle. Landscape and portrait photos
  and videos each have their own place.
- Watermarks: a watermark can be for landscape photos and videos only,
  or for portrait ones only, so that you can have one mark for each
  ("Put it on landscape / portrait photos and videos" in its editor).
- Overlays: the simple row and column (Generic → Simple) now come for a
  sidemount pair too: choose "Sidemount" and both tanks show, each under
  its own name.
- Overlays: "Two rows for portrait" under Generic → Simple, dark and
  light: the same values in two rows with large letters, across the
  bottom of an upright photo or video, where the one-row overlay gets
  small.
- Watermarks: several watermarks on the same photos and videos (a logo
  and a name, say): tick the ones you want on the Color and Resize pages.
- Watermarks: a text watermark can have any colour, not only the four in
  the list.
- Watermarks (computers): the sample picture you place a watermark on
  can be a video too; its middle frame is shown.
- Color and Resize (Android): "Save to" lets the results go into a
  folder you pick instead of a new album in the gallery, as on the
  iPhone. Not yet tried on a phone.
- Color and Resize (iPhone, iPad): "Save to" lets the results go into a
  folder you choose in Files (on the phone, iCloud Drive or a drive)
  instead of a new album in Photos. The choice is remembered for both
  pages.
- Dive Logs (desktop): the page the phones have. Import your logs (a
  Garmin "Export Original" zip as it is) and they are kept in the app, so
  the Color page and the Overlay Generator find the dives without a folder
  being set up first.
- Color and Resize (phones and tablets): "From Files" beside the library
  pick, for photos and videos that a camera card, a drive or a cable copy
  left in the Files app (iOS) or a folder (Android) and that are not in
  the photo library.
- Overlays: VSAC (gas use in litres a minute) is worked out for dives
  whose log has tank sizes and pressures but no VSAC of its own (UDDF,
  Subsurface, Suunto), so the X50i and other VSAC fields show a value
  instead of `--`.
- Tank Sensor Names: each sensor can have a tank size in litres, so
  Garmin dives whose watch did not log VSAC get one from the transmitter
  pressures (and any log without sizes of its own).
- Overlay Designer: the sample dive has SAC and VSAC, so those fields can
  be checked in the preview.
- Overlay Designer: arc gauges and segment bars under Add element. An arc
  fills a circular track by a value (NDL, time to surface, tank pressure),
  with optional divisions; a segment bar lights a stack of segments by a
  value (an ascent-rate bar, 2 m/min a segment). Set their range, angles,
  segments and colours in the inspector.
- Overlay Designer: a text element can sit on a filled Box of its own
  colour (a Nautic's stop timer); empty the Box field for none.
- Dive logs: Suunto app dive exports (.json, from the EON Steel / EON
  Core, Nautic, D5 and Ocean) open in the Log Viewer, the Overlay
  Designer and the Dive Profile Builder, with the computer's own no-deco
  time, time to surface, ceiling, tank pressures (also sidemount), gas
  time, gas switches and alarms. Other JSON files in a log folder are
  ignored.
- Dive Profile Builder: an opened Suunto export brings its gases, tank
  sizes and gas switches into the plan.
- Overlays: templates for the Suunto EON Steel Black and EON Core, laid
  out from Suunto's product photos and the manuals: the Classic grid with
  its ascent bar and no-deco scale, Classic (CCR), Prominent with its
  no-deco arc, Prominent: tank, Graphical and the Gauge timer. The arc
  turns orange with the ascent time in deco and yellow with the stop
  counter at the safety stop.
- Overlays: templates for the Suunto Nautic: the Main Screen with its
  cells, the amber safety-stop pill, the orange DECO tag and the red
  warning panel, in single-tank and sidemount variants (both tanks'
  pressures with their bars), and an NDL / TTS, ppO2 / MOD page. The Dive
  Profile Builder can pose as the EON Steel Black, EON Core and Nautic.
- Overlays: Suunto colours and alerts from the manuals: the NDL, PO2, tank
  pressure and ascent-rate colours, the safety stop counted between 2.4
  and 6 m on dives over 10 m, the deco window and its 0.6 m safe margin,
  and the device's own pop-ups (Ascent speed, Ceiling broken, pO2 high,
  Tank pressure, CNS 80%, Change gas…). A custom overlay can borrow them
  by picking Suunto as its rules.
- Overlays: a Main: AI page for the Shearwater Peregrine TX (gas, T1
  pressure with its bar, GTR) and the Perdix 3 (T1 in the top slot, gas,
  GTR and SAC), so a dive with a tank transmitter shows its tank and gas
  time on the main screen instead of an info page.
- Overlays: the Shearwater Teric and Tern pages show the ascent-rate
  arrows beside the depth with the rate as a number (m/min or ft/min), as
  the watches do.
- Overlays: on the Shearwater Peregrine TX, Perdix 2, Petrel, Teric and
  Tern a deco stop reads "6m 2min" with the units small and in blue, as on
  the real screens.
- Overlays: the Garmin Descent Mk3i pages show the watch's alerts
  ("Approaching NDL", "PO2 is high", ...) from the dive log, the message
  alone on the screen; before, the Mk3i showed no alerts at all.
- Overlay Designer: the sample sidemount dive lets the two cylinders
  drift over 35 bar apart before the first change, so the tank-switch cue
  (the Perdix box, the X50i's blue pressure and arrows, "Breathe from ...")
  can be checked without a log.
- Resize: your watermark on the copies. Choose it under "Watermark" on
  the page; it is the same choice as on the Color page.
- iPhone and Android: Settings → My overlays lists the overlays you have
  imported, each with Remove.
- Android: the notification of a run has a Stop button and shows how far
  the whole run is ("File 3 of 7"), not only the current video.
- Color: "Output size". Colour-correct, add overlays and make the video
  small in one run: choose a resolution or a copy for WhatsApp or
  Instagram / Facebook. With a cropped portrait size the preview shows
  the part that is kept, a slider moves it, and overlays and the
  watermark are placed on that part. On the computer and on the phones.
- macOS: Apple Photos beside the folders on the Color, Resize and Tag
  Editor pages. "From Photos…" opens the Photos picker for the source,
  and "Save into Photos" puts the results into a new album instead of a
  folder. The originals in Photos are left as they are.
- Resize: copies for sharing. Switch on "WhatsApp", "WhatsApp, portrait"
  or "Instagram / Facebook, portrait" and the run also makes small H.264
  copies that play wherever you send them, each with its size in
  megabytes shown beforehand.
- Resize: portrait copies of landscape video. Choose "Cropped" and drag
  the window on the preview to the part of the picture to keep, or "Whole
  picture, with bars". On the computer and on the phones.
- Overlays: six simple ones for every dive computer, under Generic →
  Simple: a row along the bottom, a column in the corner and a compact
  box, each dark or light. They show depth, dive time, NDL (the deco stop
  while in deco) and, on the row and the column, temperature, gas and tank
  pressure. On the computer and on the phones.
- Android: a run goes on when you switch to another app or the screen
  goes off. A notification shows that UWMedia is working and how far the
  current video is; tap it to come back.
- iPhone and Android: your own overlays from the Overlay Designer. Export
  the page as a zip on the computer, send it to the phone and open it with
  UWMedia (or pick it under Settings → My overlays); it is then offered on
  the Color page beside the bundled ones.
- Watermarks: put your own logo (PNG or JPEG) or a line of text on every
  photo and video the Color page makes, with or without a dive log. Add
  them under Settings → My watermarks, with a corner, a size and an
  opacity that fit any picture shape, then choose one on the Color page;
  the preview shows it.
- Color: the preview shows the colour correction of the chosen profile,
  not only the overlays, so the result is seen before a run. Press and
  hold the preview to see the picture as the camera took it, and let go
  to see the correction again.
- Resize: each size says about how many megabytes the video will be, so
  the one that fits a message or an upload can be picked before the run.
- Resize (desktop): several videos can be picked for one run; each is
  made into the chosen sizes that are not above its own.
- Settings (desktop): the dive-logs folder is one setting for the whole
  app. Set it on the Color page, the Overlay Generator or under Settings →
  Locations, and every page uses it.
- macOS: the app is "UWMedia" (`org.christersson.uwmedia`) and runs
  outside the App Sandbox, so the file dialogs and ffmpeg work and it
  shares its settings, profiles and templates with the Python app. The
  other platforms carry the same name and id.
- App: the page menu of the Python app, as a rail on a wide window and a
  menu on a narrow one; pages not yet built say so. Phones and tablets
  list only their pages.
- Convertion (desktop): downscale a video to 1080p, 720p, 480p and 360p in
  one go, with the file names shown before the run, a progress bar with
  the time left, Stop, and the date and timezone carried over to each
  file.
- Tag Editor (desktop): a folder's photos and videos with their four date
  tags, DJI's corrected dates, Write, Revert, "Update All (DJI)", one
  timezone for every file of the folder (after a question), and a
  viewer of all of a file's tags with a filter.
- Tag Editor (desktop): "Shift all files" moves the date of every photo and
  video in the folder by the same hours and minutes, for a camera whose
  clock was wrong, optionally giving them a new timezone offset; files
  that could not be written are named afterwards.
- Color (desktop): colour-correct a folder of photos and videos, or one
  file, and burn in overlays for the dive of the moment each was taken:
  a live preview of the first file with the overlays you add from the
  bundled and your own templates, moved and resized with the mouse; the
  clock offset between camera and dive computer, nudged or set from the
  dive time the computer shows in the frame; naming, "Skip if target
  exists" and hardware encoding; up to four files at once with progress,
  the time left and Stop.
- Dive Profile Builder (desktop): build a made-up dive for testing
  overlays: set the scale, click waypoints into the chart and drag them,
  give gases depth ranges, end the dive with its safety or deco stops,
  hover for depth, gas, PO2, NDL or deco, CNS and tanks, and save it as
  UDDF, Garmin FIT or Subsurface XML; open such a log again to edit it, or
  import another log as a plan. Open circuit, sidemount and CCR.
- Overlay Designer (desktop): edit an overlay page on its skin: pick it by
  brand, computer, page and tank setup; click, Cmd/Ctrl-click or drag a
  box to select elements, drag or nudge them with the arrow keys, snap to
  a grid and to each other, align, distribute, resize, copy and paste,
  undo and redo; every element's look in the inspector; add text, labels,
  badges, tank icons, the depth graph, tissue bar, ascent chevrons,
  notices and tank switch arrows; preview on the dummy dive at any time or
  in a forced state, played at 10x, in metres or feet, in Design view or
  on a full frame. The bundled pages are read-only: Save as makes your
  own copy, and New custom starts a page on your own image or a rounded
  rectangle. A page you save is offered at once on the Color and Overlay
  Generator pages.
- Overlay Designer (desktop): under More, put a photo or video behind
  Frame preview and scrub through it, load dive logs and see the sample
  for each moment (with the hours between the camera's and the log's
  clocks), preview a loaded dive on its own, look at the raw data of the
  sample shown, and export a page as a zip or import one as a new page.
- Tag Editor (phones and tablets): pick photos and videos from the library
  and see their dates and timezone offsets; set one file's date, or shift
  them all for a camera whose clock was wrong; the corrected copies are
  saved into a new album, and the originals stay as they are.
- Dive Logs (phones and tablets): import your dive logs (Garmin .fit, or
  the zip Garmin Connect's "Export Original" gives; Shearwater and
  Subsurface exports, UDDF), see their dives, remove a log; with
  step-by-step help for getting the logs off Garmin Connect and
  Shearwater Cloud.
- Dive Logs (phones and tablets): "Open with UWMedia" and "Share to
  UWMedia" for a .fit, .uddf, Subsurface or Shearwater file (or Garmin's
  zip) from Files, Mail or the browser: the log is kept and the Dive Logs
  page opens with it listed.
- Color Tuning (phones and tablets): pick a photo and tune a colour profile
  with one slider per stage (blend, red restore, blue reduce, de-haze,
  exposure, darkness, sharpness), the original beside the result; save it
  for the Color page.
- Color (phones and tablets): pick photos and videos from the library, colour-correct
  them and burn in overlays for the dive of the moment, matched against
  the logs kept in the app; the same live preview with the overlays moved
  and resized by touch, and the same clock offset, as on the desktop. The
  results go into a new album; the originals stay as they are. The screen
  stays on while a run goes.
- Convertion (phones and tablets): downscale a video from the library to 1080p, 720p,
  480p or 360p (HEVC), each saved into a new album with the video's date.
- Color Tuning (phones and tablets): a video's frame can be the sample, as
  well as a photo.
- iPhone: photos picked from the library come as the files they are, under
  their own names: an HEIC stays an HEIC and a corrected copy from the Tag
  Editor keeps the picture untouched (before, every photo was compressed
  again as a JPEG on the way in).
- iPhone: an export that iOS interrupts (the screen locked, the app left)
  starts again when you are back in the app, and says so if it cannot.
- Windows: the app is `uwmedia.exe`, named "UWMedia" in its window and
  file details.
- Settings (phones and tablets): metric or imperial units, the default
  colour profile, how output files are named, hardware encoding, and the
  names and order of your Garmin tank sensors, read from logs you pick.
- About: the app's version, a check for a newer release, the licence,
  the ffmpeg and exiftool in use, the overlay fonts and every open-source
  licence, and the links.
- Advanced (desktop): metric or imperial units for the whole app, the
  folders of your layouts, templates and colour profiles, the ffmpeg and
  exiftool the app uses (checked before they are taken), and the tank
  sensor names with their order, filled from a folder of Garmin logs.
- Overlay Generator (desktop): render overlays on their own, to lay over
  footage in an editor: for every video and photo of a folder, matched to
  its dive, or for a whole dive of one log file; as transparent ProRes
  4444, a PNG sequence or video on black, at the template's size, 4K or
  the full frame, with progress for each overlay and for the batch.
- Overlay Generator (desktop): a custom layout can also be one of the
  older `.zip` HUD packages (a layout with its skin image), as in the
  Python app; the outputs are named after the zip.
- Color Tuning (desktop): load a sample picture and see it corrected
  beside the original while you move the 26 colour sliders; start from
  any profile, reset a slider, and save the profile or a new one for the
  Color page.
- Log Viewer (desktop): open dive log files or a folder and see every dive
  as UWMedia reads it: the fields, tanks and sensors, the depth profile,
  a rebreather's PO2 strip, the events and every sample with a filter.
  Garmin logs get "Adjust time" for a wrong dive computer clock and
  "Merge" for a dive split in two; both save a new file.

### Changed

- Computers: the ffmpeg in the download is now the same version, 9.0.2,
  on Windows, macOS and Linux, built by the project itself with its
  source published beside it; your own ffmpeg still works in its place.
- Computers: until a folder has been picked in it, a dialog for photos
  and videos opens in your Pictures folder and one for dive logs in
  Downloads, where an export lands, instead of your home folder.
- Windows: the app comes as an installer (`UWMedia-windows-x64-<version>-setup.exe`)
  instead of a zipped folder; it installs for you alone or, with
  administrator rights, for everyone, with a Start menu entry and an
  uninstaller.
- Color, computers: a long clip's colour fades are prepared several at
  once, so a run gets to the encode sooner, and Stop ends it within
  about a second while they are prepared (it waited until all were
  done).
- Overlays: a photo or video from the surface before the descent, after
  the dive computer started the dive, shows the overlay with the depth as
  "--" until you go down (it showed 0.0 m).

- About: "Report a problem" now also tells what the Tag Editor wrote or
  could not write, the logs imported or removed on Dive Logs, and each
  file saved into Photos or a folder on a phone, so a problem there can
  be reported too.
- Color, Overlay Generator: in a video, a flashing value now really
  flashes, half a second in its warning colour and half a second not, as
  on the dive computer: a depth above a broken deco ceiling, a ppO2 out
  of range, a tank at its critical reserve, the fastest ascent rate. A
  photo keeps the warning colour. Before, a flashing value stayed in its
  warning colour in a video too.
- Mac: "Save to…" → "An album in Photos…" on the Color, Resize and
  Overlay Generator pages asks which album, as on the iPhone: one of
  your albums, or a new name. The album is remembered; before, the entry
  asked nothing and made a new album for each run.
- Color, Overlay Generator: a run starts at once instead of reading
  every dive log again first; it takes the dives the page has already
  read. A log added or changed since, or other tank names, is still
  read again.
- Color: a video now gets the same colours as a photo with the same
  profile. The video's colour correction carried the profile's
  sharpening in a way that sharpened nothing but moved some colours a
  little; videos are still not sharpened.
- Phones: an overlay zip opened with UWMedia or shared to it is no longer
  added, since a phone has no way to remove it again. Overlays are added
  on a computer.
- Color, "Output size": a list of sizes only, in its own card. Whether
  the videos are written as shot or in portrait is chosen above the
  preview, and works with every size, the videos' own included.
- Resize (computers, FFmpeg): with "Hardware acceleration" on the source
  is now decoded by hardware too where that is safe. A 4K HEVC clip from
  an action camera that took four and a half minutes to bring to 1080p
  takes half a minute.
- Color (phones and tablets): an upright photo or video no longer fills
  the screen; the preview takes at most about two fifths of its height.
- Settings (phones and tablets): "My overlays" is gone from the page.
  An overlay zip from the Overlay Designer is still added by opening it
  with UWMedia or sharing it to the app; an added overlay cannot be
  removed in the app for now.
- Dive Logs: the page opens at once. Each log is read when it is
  imported or changed, not every time the page is opened.
- Color: "Resize…" opens the output size, and for a portrait size the
  crop window, dragged on the picture as it was on the Resize page. The
  overlays and the watermark are laid on the part that is kept, so the
  crop belongs here.
- Resize: one list of sizes. WhatsApp, WeChat (new) and Instagram /
  Facebook stand beside 1080p to 360p and keep the video's shape; the
  crop and the portrait copies have moved to the Color page.
- Color, Resize, Color Tuning (phones and tablets): one button to pick
  photos and videos, which asks whether from the photo library or from
  Files, instead of two buttons.
- Color: each added overlay has its own remove button, and the list takes
  only the room of its overlays. "Add Overlay" opens on the overlay you
  added last time instead of starting from the first brand.
- Color, Resize, Overlay Generator (computers): the photos and videos
  are chosen with one button, as on the phones: one file or several at
  once, or on a Mac the Photos library. A "Save to…" button chooses where
  the results go (a folder, or on a Mac a new album in Photos), and the
  place chosen stands under it. Paths are no longer typed.
- Color, Resize, Tag Editor (Mac): after you pick from the Photos
  library the page says "Fetching … from Photos…" until the files have
  come, which takes a while for ones still in iCloud. "Cancel" beside it
  gives the pick up.
- Overlay Generator (Mac): photos and videos can be picked from the
  Photos library, and the overlays can be saved into a new album in
  Photos (not for a PNG sequence, which is a folder of frames), as on
  Color and Resize.
- Tag Editor (computers): one "Choose photos and videos…" button, as on
  Color and Resize: files picked one or several at a time, a folder, or
  on a Mac the Photos library. Picking single files is new.
- Log Viewer: one "Open dive logs…" button: files, a folder, or the
  logs you have imported on the Dive Logs page, without looking for
  where they are kept.
- Color Tuning (Mac): "Load Image…" can take the sample photo from the
  Photos library.
- Color and Resize (phones and tablets): the place the results are saved
  to stands under the "Save to…" button instead of on it, so the button
  stays short.
- Dive logs (computers): the pages read only the logs imported on the
  Dive Logs page; the dive-logs folder is gone from Color, the Overlay
  Generator and Settings. If you had a folder set, the Dive Logs page
  offers to import its logs once.
- Color, Overlay Generator: a button says whether your photos and
  videos have their dive logs: green when every file is matched to a
  dive, orange when some are not, red when none is. Press it for the
  list of the files with the dive each was matched to. The separate
  "Dive Logs…" button is shown only while no log is imported; from the
  list it is one press away when a file has no dive.
- Overlay Generator: an overlay for a whole dive is made from a dive
  chosen in a list of your imported logs, instead of a log file.
- Color (computers): the clock offset is one line showing the offset
  set, opened when you want to change it, as on the phones, and the
  preview's box starts level with the "Color correction" box beside it.
- Overlay Generator: the overlay picker starts on the overlay you added
  last time instead of the first brand.
- Color (computers): a long video is analysed several times faster (under
  a minute instead of six for a 16-minute 4K clip), starts encoding at
  once instead of after a wait of minutes, and needs far less memory and
  temporary disk space while it runs.
- Color (phones and tablets): the clock offset is one line showing the
  offset set, opened when you want to change it, and the count of dive
  logs is gone, so the page is shorter.
- Resize (phones and tablets): the output sizes stand in two columns.
- Color Tuning (phones and tablets): one large picture instead of two
  small ones (press and hold it to see the original). It stays in view
  while you scroll the sliders, and Save asks whether to overwrite the
  profile or save a new one.
- Color: a video whose colour changes along the way now moves smoothly
  from one correction to the next, on computers, phones and tablets.
  Before, the colour jumped every two seconds where the light kept
  changing (a descent, a swim towards the surface). On a computer such a
  video takes about as long to write as one with a single correction.
- App icon: the UWMedia icon of the Python app on every platform, instead
  of Flutter's placeholder.
- Color (phones and tablets): picking the photos and videos comes first
  on the page, above the preview, instead of far down under the settings.
- Color (phones and tablets): Start stays at the foot of the screen
  wherever the page is scrolled to. While a run goes the page shows only
  the picture, the progress and Stop; afterwards how it ended stands above
  Start and its messages are in a "Last run" card at the end of the page.
- Resize (phones and tablets): the same. Start stays at the foot of the
  screen; while a run goes the page shows only the video's name, the files
  being made, the progress and Stop; afterwards how it ended and how long
  it took stand above Start.
- Dive Logs (phones and tablets): the kept logs are listed by month, the
  newest month open and the others folded, so a long list stays short.
- Color: when no dive matches the file, the preview says which time the
  logs were searched for, so a camera clock that is hours off (or a
  missing timezone) is seen at once.
- Desktop: the window opens at a size that fits the screen (most of it,
  at least 1280 x 800) instead of a small one, remembers its size, place
  and whether it was maximised, and cannot be made smaller than 1100 x
  720, the least the pages fit in. A window left on a screen that is gone
  opens on the main screen again.
- App: the "Convertion" page is now "Resize", and the desktop's "Advanced"
  page is "Settings", as on the phones.
- Color: photos are colour corrected about ten times faster (a 25-megapixel
  photo in about two seconds instead of twenty), with exactly the same
  result, and the page stays responsive while they are.
- Color, Color Tuning: the preview's colour correction is drawn by the
  graphics card, so scrubbing through a video and moving a tuning slider
  show the corrected picture at once instead of after half a second.

### Fixed

- Android: a video converted from a camera that records uncompressed
  sound (PCM) now plays with sound on the phone; the sound was kept but
  in a form phone players do not play.
- Android: picking a large video in Files (a camera clip in a cloud folder,
  for example) no longer closes the app.
- Color, Windows: the colour-corrected preview of a photo or a video
  frame is no longer upside down (Color Tuning's was right only when
  sharpening was on). The files written were never affected.
- Overlay Designer, on a computer: the design view is sharp on a screen
  scaled to 125 or 150 % (as is usual on Windows); it was drawn at
  fewer pixels than shown and blown up, so text and lines looked coarse.
- Color, phones: the page shows at once when the app starts; with many
  dive logs kept in the app it stayed empty for several seconds (about
  8 s on an iPhone with 119 logs) while they were read. It now says
  "Reading the dive logs…" until they are.
- Color and Overlay Generator, computers: a long clip on a nearly full
  disk stops at once saying how much room the run needs and how much is
  free, instead of filling the disk (about 1.4 GB an hour of clip).
- Android: a dive log picked on the phone keeps its own name; the
  picker passed a `.fit` log on as `.bin`, and Dive Logs refused it as
  "not a dive log". A FIT log saved under another name is now also
  known as FIT by its contents, and kept as `.fit`.
- Color: removing the file while a part of a video was set no longer
  leaves the page with an error.
- Windows: a folder under your home folder is shown short, as `~\…`,
  as it is on a Mac (the whole path was shown).
- Overlay Designer, Windows: your own pages with tank variants (single
  tank, sidemount) open; they said the page's file was missing.

- Dive Logs: the same dive in two logs (a log imported twice under
  different names, or one dive exported in two formats) is listed once.
  The other log says which log holds the dive, and the month's count
  no longer counts it twice.
- Overlays, Garmin Descent X50i: the tank icons on Main and CC stand level with
  the foot of the pressure digits; they hung a little below them.
- Color: on a computer the live preview keeps the picture's own shape,
  and the box around an overlay sits on the overlay. The picture was
  stretched to the width of its card, so the box drifted off the overlay
  the further right it was moved, and the overlay lagged the mouse.
- Color Tuning: the sliders open at the values of the profile shown. They
  were at other values for Sharpness and Darkness, so the preview did not
  show what a run with that profile does.
- Windows: a long clip whose colour changes often no longer risks a run
  that will not start because its command is too long.
- Color and Overlay Generator: a photo or a part of a video taken more than
  a minute before or after the dive shows "--" in the overlay, where it
  showed the dive's first or last values (a photo on the boat half an hour
  before the dive looked as if taken under water).
- Mac: what is picked from Photos no longer fills the disk. A page's
  copies of its earlier pick are removed when it picks again, where they
  were kept until the app was started a day later.
- Color (Mac, FFmpeg): a video could lose frames with "Hardware
  acceleration" on (90 of 2832 on a Sony 4K clip at 50 frames a second),
  so that it came out shorter than its sound. A Sony camera's H.264
  videos are now decoded by FFmpeg itself on a Mac, which loses none and
  is faster for them. A run also says so when a result has fewer frames
  than its source.
- iPhone, iPad: saving into Photos works when UWMedia has access to
  chosen photos only (or to add photos only). Photos allows no album
  then, so the results go into the library without one, and the run says
  that full access is needed for an album. Before, nothing was saved.
- Phones and tablets: a Sony camera's video now has its timezone and
  local time. Tag Editor showed only the UTC date, the Color page looked
  for the dive at the UTC time and found none, and the results lost the
  local time; the camera's own timezone tag is read now, and the result
  gets the local time with its offset as on the desktop.
- Color (phones and tablets): logs imported or removed on the Dive Logs
  page are matched to the file already picked at once; before, the preview
  kept saying that no dive matched until the file was picked again.
- Color Tuning (phones): the line under the buttons shows the picked
  picture's name instead of its whole path, which took several lines and
  left little room for the sliders.
- Color: a video whose colour changes along the way (from the shallows
  down to depth, or a torch switched on) now gets the correction of each
  part. Before, a computer used the correction of the clip's first seconds
  for all of it; the phones already followed the change.
- Color: a video or photo whose analysed frame is completely black (a clip
  that fades in from black) no longer fails; that frame gets no
  correction.
- Color: the colour correction of a camera's video looks at its frames as
  the Python app does, so a clip gets the same correction in both apps
  (camera clips are tagged BT.709, which the analysis read differently
  and which could move a clip's red by a few percent).
- Color (iPhone): the colour correction of a video now comes out as on
  the desktop for the same clip and profile; before, the iPhone read the
  frames for the analysis and applied the correction with other colour
  conversions, enough to change the result visibly on underwater footage.
- iPhone: pressing Stop during a video export with sound no longer
  crashes the app.
- iPhone: when the phone is locked or UWMedia is left during a video
  export, the export starts again from the beginning once the app is back;
  the progress now goes back with it and a message says so, instead of
  standing still as if it had stopped.
- Color: videos are corrected as in the Python app again; footage with
  sharp colour edges could come out noticeably bluer.
- Tag Editor: the timezone Mode list no longer runs past the edge of a
  narrow window.
- Overlay Designer: a notice's Style buttons (Text, Banner, Box, Frame)
  wrap inside the inspector; Frame ran past the panel's edge, where it
  could hardly be clicked.
- Overlays: the Shearwater Peregrine TX, Perdix 2, Petrel, Perdix 3,
  Teric and Tern pages draw their text at the manuals' sizes in a tall
  condensed font: depth, dive time, NDL, stop badges, info rows, Tec / CC
  rows and gauge pages were a half to two thirds as tall as on the real
  screens. Feet fit before the ascent arrows, and a deco stop's ↑ / ↓
  marker shows.
- Overlays: the Shearwater Perdix 3 Main Screen and Standard pages show
  the breathing gas's O2 percentage from the log (32% for Nx32, 18/50 for
  a trimix) above the gas badge; it read 21% whatever the gas.
- Overlays: the Garmin Descent X50i pages fit the watch's real display;
  the bottom row ran past the display's lower edge and the right column
  over the dark glass by the light sensor.
- Overlays: Shearwater Perdix 2, Peregrine TX and Petrel warnings sit under
  the blue line and inside the screen, instead of touching the line and
  running onto the bezel at the bottom left.
- Overlays: a Shearwater tank pressure below the reserve gets a yellow /
  red box that hugs the digits, as in the manuals, instead of covering the
  tank label, the pressure bar or the blue line.
- Overlays: the vertical BAR / PSI beside a Shearwater tank pressure runs
  the digits' full height, level with them, instead of sitting small and
  raised (sidemount pages included).
- Overlays: the Shearwater Perdix 3 safety-stop time sits below the SAFETY
  box instead of overlapping it.
- Overlays: the warning triangle on Garmin Descent X50i alerts shows its
  exclamation mark.
- Overlays: Tec and CC pages on the Perdix 2, Petrel and Perdix 3 show
  time to surface in whole minutes, and the Perdix 2 and Petrel Tec / CC
  screens are black instead of a grey panel with fixed ascent arrows. The
  Teric and Tern Main pages show the gas as its O2 percentage with the
  cylinder, and the Tern's right slot shows MAX by default.
- Color, Overlay: a run with a dive-log folder no longer stops at once with
  "object is unsendable"; the logs are read and the run goes on.
- Color, Overlay, Resize (desktop): videos from DJI cameras run with
  ffmpeg 9 instead of failing with "ffprobe gave no size", and keep their
  real bit rate and frame count.
