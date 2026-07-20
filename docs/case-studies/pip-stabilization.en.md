# Stabilizing Picture in Picture for WebRTC calls

## Initial problem

PiP startup was unreliable when the app entered the background: AVKit could retain a black frame,
fail to start PiP, or lose its association with the active WebRTC session after the app returned.
A routine Simulator smoke test did not reproduce the complete CallKit, camera-capture, and process
lifecycle behavior.

## Observed system

Diagnostics separated four state machines:

1. the WebRTC media session and arrival of remote frames;
2. source-view readiness for `AVPictureInPictureVideoCallViewController`;
3. the `AVPictureInPictureController` lifecycle;
4. process and call identity before backgrounding and after foreground restoration.

Every diagnostic record carried a call ID and launch ID. Evidence contained XCTest logs, JSONL
events, and screenshots before Home, on Home, and above another application.

## Tested hypotheses

### Automation destroys the original call session

In some runs, `XCUIApplication.activate()` after Home created a new process and launch ID. Such a
run could not prove PiP continuity even when the final screen looked correct. The gate was changed:
evidence is accepted only when call and launch identity remain unchanged.

### The AVKit source view is not ready

PiP startup was tied to a confirmed remote-video source rather than signaling state alone.
Diagnostics received separate configure, start, didStart, and failure events with a bounded timeout.

### Incorrect frame geometry

`resizeAspectFill` combined with a full-screen portrait source produced excessive cropping. The
PiP-only renderer uses `resizeAspect` with a preferred content size of `160x90`; the full-screen
renderer retains its own presentation policy.

## Automated evidence

Physical regression ran on two iPhones and validated:

- connected audio and video media;
- a remote frame before backgrounding;
- a PiP window on Home and above Settings;
- no black placeholder;
- stable call and launch IDs;
- no startup failure or timeout events;
- return to the foreground without a new call session.

The visual analyzer measured luminance and frame changes as diagnostic signals. Motion was not made
a hard gate because a real participant can remain still. A non-black frame and preserved session
identity remained mandatory.

## Result

The production-shaped path using `activeVideoCallSourceView` and
`AVPictureInPictureVideoCallViewController` passed repeated physical-device runs, including PiP
retention above another application. A separate sample-buffer path remains available as a
diagnostic fallback but is not the primary UI flow.

## Lessons

- a UI automation action can modify the lifecycle system under investigation;
- a visual pass without identity correlation does not prove continuity of the original call;
- Simulator and physical-device runs are distinct test layers;
- increase a timeout only after measuring the event that fails to arrive;
- evidence must preserve successful and unsuccessful phases.

The raw working log is intentionally excluded because it contained environment-specific run IDs
and local artifact paths. This document retains verifiable engineering decisions without coupling
them to one private test bench.
