# AirVeil

A native macOS app that uses AirPods head motion to progressively blur the opposite side of the desktop: look left to obscure the right, and look right to obscure the left.

## Development status

Research and platform validation are in progress before implementation. macOS is the first test platform; iPhone and iPad feasibility is evaluated separately.

## Intended behavior

- AirPods motion input with explicit center calibration and connection status.
- Smooth, angle-dependent desktop blur with a feathered boundary.
- Adjustable activation angle, strength, response speed, and direction.
- Live desktop interaction through a click-through overlay.
- Menu-bar controls, preview, pause, and a quick way to clear the overlay.
- Local processing of motion and screen frames.

Software blur is visible to everyone looking at the display. It does not create different images for different viewing angles.

Research reports, implementation decisions, and validation evidence will be stored in this repository.
