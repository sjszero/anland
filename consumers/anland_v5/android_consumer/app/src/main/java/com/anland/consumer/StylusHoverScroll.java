package com.anland.consumer;

/** Converts vertical pen movement while a side button is held into wheel deltas. */
final class StylusHoverScroll {
    private boolean active;
    private float lastY;

    float update(boolean hovering, boolean sideButtonPressed, float x, float y,
                 float sensitivity) {
        if (!hovering || !sideButtonPressed || !Float.isFinite(y)) {
            reset();
            return 0f;
        }
        if (!active) {
            active = true;
            lastY = y;
            return 0f;
        }

        // Horizontal displacement is intentionally ignored; diagonal motion keeps
        // only its vertical component for a predictable vertical wheel.
        float deltaY = y - lastY;
        lastY = y;
        return -deltaY * sensitivity;
    }

    void reset() {
        active = false;
    }
}
