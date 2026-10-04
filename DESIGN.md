---
name: Rehab Session
description: Calm white rehabilitation dashboard with measured organic progress surfaces.
colors:
  white: "#FFFFFF"
  ink: "#252B29"
  muted: "#656C68"
  line: "#E8EBE8"
  sage: "#47664F"
  lilac: "#78658C"
  grain-base: "#E8E3DE"
typography:
  display:
    fontFamily: "Manrope"
    fontSize: "34px"
    fontWeight: 600
    lineHeight: 1.15
    letterSpacing: "-1.1px"
  body:
    fontFamily: "Manrope"
    fontSize: "15px"
rounded:
  summary: "24px"
  cta: "18px"
  progress: "2px"
spacing:
  xs: "4px"
  sm: "8px"
  md: "16px"
  lg: "24px"
components:
  button-primary:
    backgroundColor: "{colors.ink}"
    textColor: "{colors.white}"
    rounded: "{rounded.cta}"
    height: "56px"
---

# Design System: Rehab Session

## Overview

White, quiet, mobile-first session review. Organic color belongs to the static progress surface; navigation and actions remain restrained.

## Colors

Ink carries text and CTA; sage and lilac distinguish exercise progress. The summary field is native GLSL (`shaders/rehab.frag`): lilac, sage, peach, and grain over a light neutral base.

## Typography

Manrope is the bundled family. Use 34px/600 display for the session heading, 20px/600 section titles, 15px body, and 12–13px metadata.

## Layout

Content is constrained to 480px, padded 24px, and scrolls above fixed 56px CTA and 60px Cupertino tab bar.

## Elevation & Depth

Flat white surfaces with a line divider; texture, not shadow, gives the summary depth.

## Shapes

Clip the grain summary at 24px. CTA uses 18px corners; progress marks use 2px corners.

## Components

Brand mark: an open r-shaped movement path, diagonal stride, and detached sensor
dot in sage. Master vector: `assets/brand/rehab-mark.svg`; header size 28px.
Keep the lowercase Manrope wordmark and do not animate the logo.

Primary CTA is white-on-ink with `CupertinoIcons.arrow_right`. Bottom navigation uses Cupertino icons and ink active state. `GrainSurface` is decorative only and falls back to neutral if shader loading fails.

## Do's and Don'ts

- **Do** keep background white and progress accents sage/lilac.
- **Do** verify phone layouts and large text. This revision was reviewed with Flutter golden-test screenshots; browser access was unavailable.
- **Don't** replace GLSL grain with a gradient or animate it.
- **Don't** add shadows to create depth.
