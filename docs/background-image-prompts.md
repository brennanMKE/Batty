# Background image prompts

Prompts for the 24 images in the three hosted background sets listed in
`website/backgrounds/catalog.json`: eight per set, so each set fills two even rows of four on
the website's Backgrounds page. Each image sits behind terminal text, usually at reduced
opacity over a dark theme, so the prompts favour dark, calm, low-contrast pictures with their
subject kept away from where text sits.

## What to generate now

Images 01–05 in each set already exist. Generate only **06, 07 and 08** in each set: nine new
images.

## Output

- **Size: exactly 3840 × 2400 pixels (16:10).** Every image in the catalog is this size,
  so the sets match on the website and in Batty. Most image generators can't produce that size directly (the first
  batch came out at 1586 × 992). If yours can't:
  1. Generate at the largest size the generator supports, as close to 16:10 as it allows.
  2. Upscale it 4× with Real-ESRGAN, using the official macOS release
     (`realesrgan-ncnn-vulkan-20220424-macos.zip` from
     https://github.com/xinntao/Real-ESRGAN/releases/tag/v0.2.5.0):
     `realesrgan-ncnn-vulkan -i in.png -o up.png -n realesrgan-x4plus -m <unzipped>/models`
  3. Resize to exactly 3840 × 2400: `sips -z 2400 3840 up.png --out 06-name.png`. If the
     generated image isn't close to 16:10, crop it to 16:10 first rather than stretching it.
  4. Confirm: `sips -g pixelWidth -g pixelHeight 06-name.png` must print 3840 and 2400.
- **Format:** PNG or JPEG. PNG is preferred; JPEG (quality 90 or higher) is fine where PNG is
  too large. A JPEG file's extension is `.jpg`, and its catalog `full` or `thumbnail` changes to match.
- **File names and folders:** exactly as listed under each prompt, under `website/backgrounds/`.
- **Thumbnails:** don't generate them. Make each one from its full-size image, 480 × 300:
  `sips -z 300 480 01-skyline-fog.png --out 01-skyline-fog-thumb.png` (for a JPEG thumbnail, add
  `-s format jpeg` and use `.jpg`).
- **Catalog:** add each new image to its set in `website/backgrounds/catalog.json`, after the
  last one, as `{ "title": "…", "thumbnail": "…", "full": "…" }` with a short title. Then run
  `python3 tools/check-backgrounds.py website/backgrounds/catalog.json`; it must print `OK`.
- **Web page:** run `python3 tools/build-backgrounds-page.py` to rebuild
  `website/backgrounds.html` from the catalog.
- Adding, checking and deploying: see "Background images" in `website/README.md`.

## Rules for every image

Add this block to every prompt below.

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
