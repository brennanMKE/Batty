# Background image prompts

Prompts for the 15 images in the three hosted background sets listed in
`website/backgrounds/catalog.json`. Each image sits behind terminal text, usually at reduced
opacity over a dark theme, so the prompts favour dark, calm, low-contrast pictures with their
subject kept away from where text sits.

## Output

- **Size:** 3840 × 2400 (16:10), PNG. If the generator can't produce that size, generate the
  largest 16:10 size it supports and record the size used.
- **File names and folders:** exactly as listed under each prompt, under `website/backgrounds/`.
- **Thumbnails:** don't generate them. Make each one from its full-size image, 480 × 300:
  `sips -z 300 480 01-skyline-fog.png --out 01-skyline-fog-thumb.png`

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
