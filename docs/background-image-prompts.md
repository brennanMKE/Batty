# Background image prompts

Prompts for the images in the hosted background sets listed in
`website/backgrounds/catalog.json`: eight per set, so each set fills two even rows of four on
the website's Backgrounds page. Each image sits behind terminal text, usually at reduced
opacity over a dark theme, so the prompts favour dark, calm, low-contrast pictures with their
subject kept away from where text sits.

## What to generate now

Nothing. Sets 1–7 are complete: all eight images in each are in the catalog. A new set goes in as a new
`## Set N` section below, with its eight prompts, then into the catalog as described under "Catalog" in
"Output".

## Output

- **Size: exactly 3840 × 2400 pixels (16:10).** Every image in the catalog is this size,
  so the sets match on the website and in Batty. Most image generators can't produce that size directly (the first
  batch came out at 1586 × 992). If yours can't:
  1. Generate at the largest size the generator supports, as close to 16:10 as it allows.
  2. Upscale it 4× with Real-ESRGAN, using the official macOS release
     (`realesrgan-ncnn-vulkan-20220424-macos.zip` from
     https://github.com/xinntao/Real-ESRGAN/releases/tag/v0.2.5.0):
     `realesrgan-ncnn-vulkan -i in.png -o up.png -n realesrgan-x4plus -m <unzipped>/models`
  3. Resize to exactly 3840 × 2400: `sips -z 2400 3840 up.png --out 01-name.png`. If the
     generated image isn't close to 16:10, crop it to 16:10 first rather than stretching it.
  4. Confirm: `sips -g pixelWidth -g pixelHeight 01-name.png` must print 3840 and 2400.
- **Format:** PNG or JPEG. PNG is preferred; JPEG (quality 90 or higher) is fine where PNG is
  too large. A JPEG file's extension is `.jpg`, and its catalog `full` or `thumbnail` changes to match.
- **File names and folders:** exactly as listed under each prompt, under `website/backgrounds/`.
- **Thumbnails:** don't generate them. Make each one from its full-size image, 480 × 300:
  `sips -z 300 480 01-skyline-fog.png --out 01-skyline-fog-thumb.png` (for a JPEG thumbnail, add
  `-s format jpeg` and use `.jpg`).
- **Catalog:** add each new image to its set in `website/backgrounds/catalog.json`, after the
  last one, as `{ "title": "…", "thumbnail": "…", "full": "…" }` with a short title. A set that
  isn't in the catalog yet goes in as a new entry, `{ "name": "…", "images": [ … ] }`, at the
  end of `sets`, with its images in prompt order, 01 first. Then run
  `python3 tools/check-backgrounds.py website/backgrounds/catalog.json`; it must print `OK`.
- **Web page:** run `python3 tools/build-backgrounds-page.py` to rebuild
  `website/backgrounds.html` from the catalog.
- Adding, checking and deploying: see "Background images" in `website/README.md`.

## Rules for every image

Add this block to every prompt in Sets 1–4. Set 4 adds a second block, "Space rules", under its
heading. That block relaxes the star-field rule for Set 4 only. Sets 1–3 keep it as written.
Sets 5–7 show real places and hardware, so each replaces this block with its own, given under
its heading.

> Background wallpaper for a terminal app, shown behind lines of monospaced text. 16:10
> landscape. No text, letters, numbers, signs, logos, brand marks, license plates, watermarks,
> frames or UI of any kind. Dark overall: most of the frame in deep shadow, with only small,
> soft highlights and nothing near pure white. Low contrast, muted and slightly desaturated,
> limited to one or two main hues. Keep the upper-left two-thirds of the frame calm and simple
> (smooth sky, fog, haze, soft gradients or soft out-of-focus light) because that is where text
> appears; place the main subject toward the right side and the bottom third. Avoid fine,
> busy, high-frequency detail such as wires, dense foliage, grain, noise, small repeating
> patterns or star fields, especially in the calm area. Soft focus, atmospheric haze and shallow
> depth of field are welcome. Cinematic, painterly photorealism. No people facing the camera,
> no recognizable real landmarks, and no real vehicle makes or models: every design is
> original and unbranded. The image should still read as a pleasant picture when shown at
> 20–40% opacity over a black background.

Keep them dark. In the first batch, the foggy and overcast images (misty forest, sea cliffs,
pickup in fog) came out as mid-grey and are the weakest behind text. When in doubt, go darker:
night or late twilight rather than daytime fog, with large areas close to black.

## Set 1: Future Cities

Palette: deep indigo, teal and slate, with small warm window lights.

1. **`future-cities/01-skyline-fog.png`** — A distant futuristic megacity skyline confined to
   the bottom fifth of the frame: slender, tapering towers fading upward into dense blue fog,
   their windows reduced to tiny soft points of light. Above them, a vast, smooth night sky
   gradient from deep indigo at the top to a faint teal glow just above the fog line.

2. **`future-cities/02-canal-after-rain.png`** — Blue hour after rain, looking down a calm
   canal in a future city. Elegant curved towers line the right edge, softly out of focus, and
   their lights stretch as long, smeared reflections in the still water. The left half is a
   smooth, dark wall of mist with no detail.

3. **`future-cities/03-sky-gardens-dawn.png`** — Dawn over terraced garden towers whose
   hanging greenery reads only as soft silhouettes on the right third. Low clouds drift
   between the towers. The sky is an even gradient from muted slate at the top to a pale,
   dusty amber near the horizon.

4. **`future-cities/04-maglev-dusk.png`** — A single sleek elevated maglev track sweeps in a
   long gentle curve from the lower right into fog, with a faint, soft teal light trail along
   it from a passing train. Everything else is an empty, smooth dusk sky fading from charcoal
   blue to dim violet.

5. **`future-cities/05-desert-dome.png`** — Seen from far away at night, a glass-domed city
   sits low on a dark desert plain in the lower right, glowing softly from within. Gentle
   haze surrounds it. The sky above is a deep, smooth violet-to-black gradient with no stars.

6. **`future-cities/06-harbor-lights.png`** — A futuristic harbour at night. A long, low
   seawall lined with soft amber lights runs along the bottom fifth of the frame, and a few
   slender towers stand on the far right, half lost in sea mist. The water is calm and nearly
   black. The sky is a smooth, dark teal-to-indigo gradient.

7. **`future-cities/07-floating-district.png`** — At late dusk, a small cluster of floating
   platforms with softly lit, rounded pavilions hovers above a sea of low cloud in the lower
   right. The cloud sea is a smooth, dim gradient with no texture. The sky above is a deep,
   even violet fading to near-black at the top.

8. **`future-cities/08-tower-in-the-clouds.png`** — A single, impossibly tall and slender tower
   rises from the lower right into a layer of night cloud, its windows a faint vertical line of
   warm lights that disappears into the cloud. Soft cloud banks drift around its base. The
   rest of the frame is a deep, smooth blue night sky.

## Set 2: Cool Vehicles

Palette: charcoal and warm amber, with a restrained accent of deep red or teal. Every
vehicle is an original, unbranded design.

1. **`cool-vehicles/01-cafe-racer-garage.png`** — An original café-racer motorcycle in side
   profile on the right third of the frame, parked in a dim workshop. A single warm overhead
   light catches the curve of the fuel tank and the chrome of the engine. The left two-thirds
   is a bare concrete wall falling off smoothly into black.

2. **`cool-vehicles/02-expedition-truck-salt-flat.png`** — A rugged, original off-road
   expedition truck with roof rack and chunky tyres, small in the lower right of a vast salt
   flat at twilight. A low haze of dust near the ground. The sky above takes up most of the
   frame: a smooth gradient from deep blue to a thin band of muted orange at the horizon.

3. **`cool-vehicles/03-endurance-racer-night.png`** — A low, sleek, original endurance race
   car at speed on a track at night, along the bottom third, with heavy motion blur and soft
   red tail-light streaks trailing behind it. Above, only dark haze and the faint, blurred
   glow of distant floodlights.

4. **`cool-vehicles/04-pickup-fog.png`** — An original classic-style pickup truck parked by a
   quiet forest road in thick morning fog, small in the lower right. Its warm headlights glow
   softly through the mist. Tree shapes are barely visible as pale grey silhouettes; fog fills
   the rest of the frame.

5. **`cool-vehicles/05-electric-bike-rooftop.png`** — An original futuristic electric
   motorcycle with smooth, flowing bodywork, parked on a wet rooftop at night on the right
   side of the frame. A thin teal rim light traces its outline and reflects in the puddles.
   Behind it, distant city lights are blurred into large, dim bokeh against a dark sky.

6. **`cool-vehicles/06-roadster-coast-dusk.png`** — An original 1960s-style open roadster with
   long, curved fenders, parked on a coastal overlook in the lower right at late dusk, seen in
   three-quarter profile. A faint warm reflection runs along its bodywork. Beyond it, a dark
   sea and a smooth sky fading from deep blue to a thin, muted rose band at the horizon.

7. **`cool-vehicles/07-rally-car-dust.png`** — An original rally car sliding through a corner
   on a gravel road at dusk, small in the lower right, backlit so that a large, soft cloud of
   dust glows warm amber behind it. The forest beyond is only dark, simplified silhouettes
   dissolving into haze. Avoid sharp flying stones or debris; keep the dust smooth.

8. **`cool-vehicles/08-semi-truck-night-highway.png`** — An original long-haul semi truck on
   an empty desert highway at night, small in the lower right, its headlights and amber
   marker lights glowing softly. The road fades into darkness toward the left. The sky is a
   deep, even indigo, with a faint glow at the horizon and no stars.

## Set 3: Beautiful Landscapes

Palette: natural and subdued: twilight blues, soft greys, muted greens and sand.

1. **`beautiful-landscapes/01-mountain-lake-blue-hour.png`** — A perfectly still alpine lake
   at blue hour. Dark mountain silhouettes and their mirror reflections occupy the lower third.
   The upper two-thirds is a clean, pale-to-deep twilight sky with no clouds.

2. **`beautiful-landscapes/02-dunes-dusk.png`** — Smooth, sweeping sand dunes in deep shadow
   at dusk, with the last low-angle light grazing only the knife-edge ridge lines in the lower
   half. Minimal and graphic. Above, an even sky from dusty rose near the horizon to dark blue.

3. **`beautiful-landscapes/03-misty-forest-valley.png`** — Layered ridgelines of conifer
   forest receding into mist across the bottom half, each ridge paler than the one in front of
   it. Trees read as soft, simplified silhouettes, not individual branches. The upper half is
   soft, even, grey-blue haze.

4. **`beautiful-landscapes/04-aurora-tundra.png`** — A faint, soft green aurora drifting
   across a dark sky over snow-covered tundra. The horizon is low, in the bottom fifth. Keep
   the aurora dim, wide and smooth, without sharp rays, and the sky otherwise empty, with no
   visible stars.

5. **`beautiful-landscapes/05-sea-cliffs-overcast.png`** — Dark sea cliffs rising on the right
   side of the frame above a long-exposure ocean smoothed into a silky, misty surface. A
   uniform overcast sky in soft silver-grey fills the upper half.

6. **`beautiful-landscapes/06-glacier-lagoon-twilight.png`** — A still glacial lagoon at deep
   twilight. A few smooth, rounded icebergs float low on the right, faintly pale blue, with
   soft reflections. A thin mist lies on the water. The sky is an even gradient from dark
   slate blue at the top to a dim, cold blue at the horizon.

7. **`beautiful-landscapes/07-rolling-hills-night.png`** — Soft rolling hills under a late
   twilight sky, their smooth curves overlapping across the bottom third in successively
   darker shades of blue-green. A single small, rounded tree stands in silhouette on a ridge
   at the right. The upper two-thirds is a clean, deep blue sky.

8. **`beautiful-landscapes/08-canyon-dusk.png`** — Layered sandstone canyon walls on the right
   side of the frame, their smooth, curving strata in deep warm shadow, with the last faint
   light on the topmost edge. Dusky haze fills the canyon's depth. The sky is a dark, even
   gradient from muted plum to deep blue.

## Set 4: Deep Space

Palette: deep navy and near-black, with soft violet and a restrained accent of nebula teal or
magenta; small cool-white highlights kept well short of pure white. Every spaceship and
station is an original, unbranded design: no real spacecraft (such as the ISS, the Space
Shuttle or Starship), no agency, flag or mission markings, and nothing that resembles a ship
from a film, TV series or game. Every planet is fictional, not Earth, Saturn or any other
recognizable body.

Space rules. Add this block to every Set 4 prompt, after the block for every image:

> Stars are allowed, but only a handful: small, dim, soft and slightly out of focus, mostly
> in the lower and right parts of the frame. No dense or sharp pinpoint star field, no Milky
> Way band, and no stars in the upper-left two-thirds, which stays a smooth dark gradient or a
> soft, low-contrast nebula wash. Nebulas are dim, wide and smooth, with no fine filaments,
> sharp edges or bright cores. Spaceships and stations have smooth, simple hull forms lit by a
> thin rim light, without dense panel lines, greebles or surface clutter. Stars, engine glows
> and sunlit edges stay soft and dim, never near pure white.

1. **`deep-space/01-cruiser-rim-light.png`** — A close, low three-quarter view of the bow of a
   vast, original deep-space cruiser, entering from the lower right corner and filling the
   right third of the frame. Its long, smooth hull is almost black, traced by a single thin,
   cool-blue rim light from an unseen star. Behind it, a faint violet nebula wash fades into an
   even, near-black sky.

2. **`deep-space/02-ringed-planet-limb.png`** — The curved limb of a fictional ringed gas giant
   along the bottom fifth of the frame, its night side nearly black and its edge lit by a thin,
   soft line of muted teal atmosphere. The rings cross the lower right as a faint, smooth arc,
   without fine banding. Above, the sky is an empty gradient from deep navy to black.

3. **`deep-space/03-emission-nebula.png`** — A wide, soft emission nebula in dim magenta and
   violet, lying low across the bottom third and rising on the right like slow smoke lit from
   within. Keep it smooth, with no filaments, sharp edges or bright core. A few small, soft
   stars sit in the lower right; the upper left is a smooth, dark gradient.

4. **`deep-space/04-orbit-at-sunrise.png`** — A small original ship in orbit over the night
   side of a fictional planet, whose dark, curved horizon crosses the bottom quarter. A thin,
   dim amber line of sunrise is just cresting the horizon at the right. The ship is a simple
   silhouette above it, with one soft engine glow. The sky above is a smooth, deep navy.

5. **`deep-space/05-engine-trail.png`** — A small original craft, seen from behind in the lower
   right, heading away into the distance and leaving a long, soft, gently curving engine trail
   of dim teal light that fades out before the centre of the frame. The background is an even,
   dark navy-to-black gradient with a handful of soft, dim stars near the bottom.

6. **`deep-space/06-ring-station.png`** — Part of a huge, original ring-shaped space station
   curves into the frame from the right edge, its smooth inner surface catching soft, warm
   light from a distant sun, with a few small, dim window lights. The rest of the ring falls
   away into shadow. The sky behind is a deep, smooth navy gradient.

7. **`deep-space/07-fleet-dust-lane.png`** — A small fleet of distant original ships in
   silhouette, strung out in a loose line across the lower right, crossing in front of a dark
   dust lane whose edges glow faintly violet and teal. The ships are simple dark shapes with
   tiny, soft engine lights. The upper left is empty, smooth darkness.

8. **`deep-space/08-distant-galaxy.png`** — A distant spiral galaxy seen at a low tilt as a
   soft, dim oval smudge of muted blue-violet light in the lower right, with no sharp arms and
   no bright core. A single tiny scout ship crosses in front of it as a dark silhouette. The
   rest of the frame is a smooth gradient from black to deep navy.

## Set 5: San Francisco

Real San Francisco landmarks, photographed at night or late blue hour from vantage points
photographers actually use. This set replaces the house rules block with its own: real
landmarks are wanted and must be geometrically correct, and the look is an unretouched tripod
photograph, not painterly. A first round written in the painterly style read as illustration,
because it got its calm areas by blurring the subject; this round keeps the subject sharp and
small and gets its calm from dark sky, fog and water. Palette: deep navy and slate with
restrained International-Orange or sodium-amber accents.

San Francisco rules. Add this block to every Set 5 prompt, in place of the block for every image:

> This is an unretouched landscape photograph, used as background wallpaper for a terminal app
> behind lines of monospaced text. 16:10 landscape. Shot on a full-frame camera on a tripod,
> long exposure, true-to-life colour, natural tonal range, lens-sharp detail on the subject,
> minimal natural sensor noise, no HDR halo, no painterly, illustrated or CGI look. Real
> landmarks appear with accurate architecture, proportions and geometry, exactly as they exist.
> No text, letters, numbers, readable signs, logos, brand marks, license plates, watermarks,
> frames or UI of any kind. Dark overall: night or late blue hour, most of the frame in deep
> shadow close to black, only small highlights, nothing near pure white. Muted, slightly
> desaturated palette of deep navy and slate with restrained International-Orange or sodium-
> amber accents. Keep the upper-left two-thirds of the frame calm and simple through smooth dark
> sky, low fog or still dark water rather than through blur; keep the main subject crisp but
> small, toward the right side and the bottom third. No stars, no busy high-frequency detail in
> the calm area. No people facing the camera. It should read as a believable real photograph and
> still look pleasant at 20-40% opacity over black.

1. **`san-francisco/01-lands-end-labyrinth.png`** — A real photograph taken from the Lands End
   trail near the Eagle's Point labyrinth in San Francisco at late blue hour, 24-70mm lens at
   about 50mm, tripod long exposure. Dark wind-shaped Monterey cypress trees and the rocky
   headland frame the right edge and the bottom right, sharp but nearly black. In the distance
   on the right, across the mouth of the Golden Gate, the Golden Gate Bridge is small but
   clearly the real bridge, both towers and the span visible with tiny deck lights and a faint
   International-Orange glow, the Marin Headlands dark behind it. The ocean below is smooth and
   dark with a whisper of mist. The upper-left two-thirds is an even, deep blue twilight sky
   fading to navy at the top.

2. **`san-francisco/02-golden-gate-baker-beach.png`** — A real night photograph of the Golden
   Gate Bridge from Baker Beach, San Francisco, well after twilight, taken from the sand
   looking north-north-east with a 24-70mm lens at about 50mm, two-minute tripod exposure. The
   bridge stretches low across the right half and bottom third: the south tower nearer, the
   span and the north tower beyond, correct proportions, dim deck lights and muted rust-orange
   paint. The Marin Headlands behind it are a near-black silhouette. Long-exposure surf in the
   foreground is smoothed into thin silky mist over dark wet sand with a few sharp black rocks
   at the bottom edge. The sky is a smooth, very dark navy gradient, near-black at the top,
   deep slate at the horizon. Most of the frame close to black.

3. **`san-francisco/03-bay-bridge-treasure-island.png`** — A real night photograph of the San
   Francisco skyline and the western span of the Bay Bridge taken from the shoreline of
   Treasure Island at late blue hour, 70-200mm lens at about 85mm, tripod long exposure. The
   skyline and the bridge's suspension towers sit low along the bottom third and the right
   side, sharp and accurately proportioned: real towers including the rounded-top Salesforce
   Tower and the pointed Transamerica Pyramid, small and distant, with warm and cool office
   windows. The bridge's cables carry a modest string of white lights, not a light show. The
   bay in front is smooth, nearly black long-exposure water with soft reflections. The upper
   two-thirds is a smooth, deep navy sky with no clouds.

4. **`san-francisco/04-golden-gate-battery-spencer.png`** — A real night photograph of the
   Golden Gate Bridge taken from Battery Spencer in the Marin Headlands, looking south-east
   toward San Francisco at late blue hour. Photographed with a 24-70mm lens at about 35mm,
   30-second tripod exposure. The full bridge is visible and geometrically correct: the near
   north tower large and sharp in the lower right, the deck running straight to the clearly
   visible far south tower, both towers with their real Art Deco stepped portals, main cables
   draped in their true catenary between the towers. Dim sodium deck lights, the International-
   Orange paint muted by darkness. A thin layer of real low advection fog drifts under the deck
   and blurs the city lights beyond into a faint amber line on the horizon. The dark grassy
   headland slope fills the very bottom right corner. The upper two-thirds is a smooth,
   cloudless deep navy sky darkening toward the top.

5. **`san-francisco/05-alcatraz-blue-hour.png`** — A real photograph of Alcatraz Island at late
   blue hour taken from the Hyde Street Pier / Aquatic Park shoreline in San Francisco,
   70-200mm lens at about 200mm, tripod long exposure. The island is small and sharp in the
   lower right: the real rock with its long cellhouse block, the water tower and the
   lighthouse, accurate shapes, a few faint warm sodium lights on its slopes, the lighthouse
   beam off. The bay water is smooth long-exposure near-black glass with a faint thin surface
   mist. Behind it, the dark East Bay hills form a low line with a few distant amber lights.
   The upper two-thirds is a smooth deep slate-to-navy twilight sky with no clouds.

6. **`san-francisco/06-twin-peaks-fog.png`** — A real night photograph from the Twin Peaks
   summit overlook in San Francisco, looking north-east down Market Street toward downtown,
   24-70mm lens at about 70mm, tripod long exposure. A thick bank of real advection fog fills
   the lower part of the frame and the right side, lit from beneath by the city's sodium-amber
   streets; downtown's real towers, including the Salesforce Tower with its rounded crown and
   the Transamerica Pyramid, poke out of the fog small and sharp in the lower right. A dark
   grassy foreground slope at the very bottom edge. The upper two-thirds is a smooth, clean
   deep navy night sky with no stars and no clouds.

7. **`san-francisco/07-painted-ladies-alamo-square.png`** — A real night photograph of the
   Painted Ladies on Steiner Street taken from the top of the slope in Alamo Square park,
   24-70mm lens at about 50mm, tripod exposure, everything sharp. The row of seven real
   Victorian Queen Anne houses with their steep front gables, bay windows and pastel facades
   sits low along the bottom-right third, lit only by dim warm street light, with a few softly
   glowing warm windows; their architectural detail is crisp and accurate, not repeated or
   smeared. Behind and above them the downtown skyline is a sharp but dim line of small lights.
   Dark lawn and the silhouette of one tree in the bottom-left corner. The upper two-thirds is
   a smooth, very dark navy sky, near-black at the top, no clouds.

8. **`san-francisco/08-transamerica-fog.png`** — A real night photograph of the Financial
   District of San Francisco in fog, taken from Telegraph Hill / the Coit Tower parking area
   looking south with a 70-200mm lens at about 135mm, tripod exposure. The Transamerica Pyramid
   stands crisp in the right third, its real tapering four-sided form with the two vertical
   wings near the top and the dim lit spire tip, with neighbouring office towers as sharp but
   dim dark shapes beside it. A layer of real low fog wraps around the lower floors and glows a
   restrained sodium amber from the streets below. Above, the sky is smooth deep navy, slightly
   darker at the top. The building tops reach no higher than the middle of the frame.

## Set 6: Circuit Boards

Extreme macro photographs of real single-board computer and ESP32-style hardware. This set
replaces the house rules block with its own. It keeps the no-text rule strictly (unmarked
chips, no silkscreen, no logos), and meets the no-busy-detail rule with very shallow depth of
field: a small sharp area in the lower right, the rest dark bokeh. Palette: matte black or
deep green solder mask, warm copper and gold, with at most one small teal or amber LED glow.

Circuit Boards rules. Add this block to every Set 6 prompt, in place of the block for every image:

> Background wallpaper for a terminal app, shown behind lines of monospaced text. 16:10
> landscape. Extreme macro photograph of real electronics hardware. No text, letters, numbers,
> signs, logos, brand marks, watermarks, frames or UI of any kind: unmarked chips, bare
> silkscreen-free board, no component labels, no chip markings, no printed lettering anywhere.
> Dark, low-key studio lighting: a single soft rim or edge light, most of the frame near black,
> with only small, soft highlights and nothing near pure white. Low contrast, muted and slightly
> desaturated, limited to one or two main hues: matte black or deep green solder mask and warm
> copper/gold pads, with at most one tiny soft LED glow as an accent. Very shallow depth of
> field: only a small sharp area sits in the lower right of the frame; the upper-left two-thirds
> dissolves into smooth, soft, dark out-of-focus bokeh with no readable detail, because that is
> where text appears. Avoid fine busy detail, grain and noise in the calm area. Photorealistic,
> physically plausible hardware, not plastic or toy-like, not a 3D render. The image should
> still read as a pleasant picture when shown at 20-40% opacity over a black background.

1. **`circuit-boards/01-crystal-and-caps.png`** — An extreme macro of a small oval metal
   crystal oscillator beside a few tiny tan SMD capacitors on a deep green board, clustered in
   the lower right corner. A soft warm side light picks out the bright solder fillets at each
   capacitor's ends. Above and to the left, the board dissolves into soft, dark green-black
   blur.

2. **`circuit-boards/02-esp32-shield-macro.png`** — An extreme macro of the silver RF shield
   can on a small dev module, seen at a low grazing angle from the lower right. A thin, warm
   rim light traces the folded edge of the brushed metal can and the row of tiny gold
   castellated pads beneath it. Everything beyond the corner of the can melts into soft, dark
   green bokeh fading to black.

3. **`circuit-boards/03-solder-joints-glow.png`** — A macro of a few glossy, cone-shaped solder
   joints on the underside of a black circuit board, in the bottom right, each catching a tiny
   warm highlight from a low rim light. A single tiny teal LED glows softly far out of focus, a
   dim round bokeh shape in the middle distance. The rest is velvety black.

4. **`circuit-boards/04-sbc-chip-corner.png`** — An extreme macro of the corner of a plain,
   unmarked matte-black processor package soldered to a deep green board, in the lower right,
   with a soft warm rim light along its bevelled edge and the tiny gold pads around it. A
   single amber LED glows softly as a dim bokeh orb in the distance. The upper left is smooth,
   dark blur.

5. **`circuit-boards/05-gpio-header-pins.png`** — A low-angle macro looking along a double row
   of gold-plated header pins on a single-board computer, the nearest few pins sharp in the
   lower right with a soft rim light on their square tips. The row recedes into deep, creamy
   bokeh, the farther pins becoming soft golden dots that fade into darkness toward the upper
   left.

6. **`circuit-boards/06-pcb-antenna-trace.png`** — A close macro of a meandering gold PCB
   antenna trace on the end of a deep green module, its zigzag running along the bottom right
   edge of the frame and catching a soft amber edge light. The trace falls rapidly out of focus
   as it recedes. The rest of the frame is a smooth, near-black blur of dark green solder mask.

7. **`circuit-boards/07-usb-connector-edge.png`** — A macro of the brushed metal shell of a
   small USB connector at the edge of a matte black board, in the lower right, lit by a single
   cool edge light along its rounded lip. Behind it, the board falls away into smooth black,
   with a few large, very dim warm bokeh circles in the distance.

8. **`circuit-boards/08-ribbon-cable-curve.png`** — A macro of a dark charcoal flat ribbon
   cable plugged into a black connector on a deep green board in the lower right corner, a
   single thin cool rim light tracing only the top edge of the cable where it bends. The cable
   rises and exits the frame through the right edge, never crossing the left half. A single
   tiny teal LED glows very softly, out of focus. The upper-left two-thirds is smooth, near-
   black, without any grey haze.

## Set 7: World Cities

Real skylines of advanced cities around the world at night or blue hour, one city per image;
the photographic counterpart of Future Cities. This set replaces the house rules block with
its own: real skylines and landmarks are wanted and must be accurate, and city lights read as
soft distant glow rather than sharp window grids. Palette: deep navy or indigo with sodium-
amber or soft cyan city light.

World Cities rules. Add this block to every Set 7 prompt, in place of the block for every image:

> Background wallpaper for a terminal app, shown behind lines of monospaced text. 16:10
> landscape. No text, letters, numbers, signs, billboards or screens with readable text, logos
> or brand marks on buildings, license plates, watermarks, frames or UI of any kind. Dark
> overall: most of the frame in deep shadow, with only small, soft highlights and nothing near
> pure white. Low contrast, muted and slightly desaturated, limited to one or two main hues.
> Keep the upper-left two-thirds of the frame calm and simple (smooth night sky, haze, soft
> gradients or soft out-of-focus light) because that is where text appears; place the skyline
> toward the right side and the bottom third. Avoid fine, busy, high-frequency detail such as
> wires, dense sharp window grids, grain, noise, small repeating patterns or star fields,
> especially in the calm area; city lights read as soft, distant glow. Soft focus, atmospheric
> haze and long distance are welcome. Real, recognizable city skylines and landmarks are wanted
> and must be accurate to the named city. Natural, believable photography, not CGI or plastic-
> looking. No people facing the camera, no real vehicle makes or models. The image should still
> read as a pleasant picture when shown at 20-40% opacity over a black background.

1. **`world-cities/01-shanghai-pudong-haze.png`** — Late night in Shanghai, the Lujiazui
   skyline of Pudong seen from the Bund far across the Huangpu River: the Oriental Pearl Tower,
   Jin Mao Tower, the Shanghai World Financial Center with its open top, and the twisting
   Shanghai Tower, all small and low on the right side of the frame, occupying only the bottom
   third, their tops softly veiled by thin mist. Their lights are dim and warm, reflected as
   long blurred streaks in the near-black river. The sky above is very dark, a smooth gradient
   from near-black at the top to deep navy above the skyline; most of the frame is close to
   black, not grey fog.

2. **`world-cities/02-seoul-namsan-tower.png`** — Night over Seoul with N Seoul Tower on the
   dark wooded ridge of Namsan in the lower right, its top glowing softly. The city spreads
   around and below as a hazy, out-of-focus wash of dim warm light across the bottom third,
   with dark mountain ridges on the far horizon. The upper two-thirds is a clean, deep navy
   sky.

3. **`world-cities/03-singapore-marina-bay.png`** — Night over Marina Bay, Singapore, seen from
   across the still water. Marina Bay Sands and the downtown towers sit low along the right
   half of the bottom third, their lights softened by humid haze and stretched into long,
   smeared reflections in the near-black bay. The upper two-thirds is a smooth, deep navy sky
   with a faint warm glow along the horizon.

4. **`world-cities/04-new-york-midtown-river.png`** — Night over Midtown Manhattan seen from
   far across the East River in Long Island City: the Empire State Building and, to its right,
   the Chrysler Building's lit crown stand among a low, hazy skyline confined to the bottom
   third and right half, their window lights softened into a dim amber glow, reflected as long
   smeared streaks on the near-black river. The sky above is dark: a smooth gradient from near-
   black at the top to deep indigo with only a faint dim blue glow at the horizon. Most of the
   frame is close to black.

5. **`world-cities/05-london-thames-blue-hour.png`** — Late blue hour over London seen from the
   Thames riverbank in Wapping, looking west upriver. Tower Bridge sits small and softly lit at
   the centre-right on the river. Behind it on the left (south) bank the Shard rises as a slim
   glowing glass spire; on the right (north) bank the towers of the City of London, including
   the Gherkin, cluster low in haze. All of it stays in the bottom third, its lights reflected
   as gentle amber smears in the dark Thames. The sky is a smooth gradient from near-black at
   the top to deep navy just above the skyline.

6. **`world-cities/06-chicago-lakefront-fog.png`** — The Chicago skyline at night seen from far
   out on Lake Michigan: Willis Tower and the downtown towers along the bottom third on the
   right, their upper floors dissolving into low fog and their lights reduced to a soft amber
   glow. The lake is dark and calm with faint, blurred reflections. Above, a smooth, deep
   indigo night sky.

7. **`world-cities/07-tokyo-blue-hour.png`** — Late blue hour over Tokyo seen from far away,
   with Tokyo Tower glowing soft warm amber in the lower right and the low city spreading
   behind it as a hazy carpet of dim light across the bottom fifth. Mount Fuji is a faint dark
   silhouette on the distant horizon. Above, a vast smooth sky fades from deep indigo at the
   top to a dim teal band just above the haze.

8. **`world-cities/08-sydney-harbour-night.png`** — Sydney Harbour at late twilight seen from
   far across the water: the Sydney Opera House shells and the arch of the Harbour Bridge sit
   low on the right, softly lit warm, with the CBD towers behind them blurred into dim haze.
   The dark harbour water holds long soft reflections. The upper two-thirds is a clean, smooth
   navy sky fading to a thin teal band at the horizon.
