package com.anland.consumer;

import org.junit.Test;

import static org.junit.Assert.assertEquals;

public class StylusHoverScrollTest {
    @Test
    public void startsFromButtonPressPositionWithoutJump() {
        StylusHoverScroll scroll = new StylusHoverScroll();

        assertEquals(0f, scroll.update(true, true, 10f, 120f, 0.5f), 0f);
        assertEquals(-10f, scroll.update(true, true, 10f, 140f, 0.5f), 0f);
    }

    @Test
    public void usesOnlyVerticalComponentAndScalesByDistance() {
        StylusHoverScroll scroll = new StylusHoverScroll();
        scroll.update(true, true, 100f, 100f, 1f);

        // A 45-degree diagonal contributes only its vertical component.
        assertEquals(-5f, scroll.update(true, true, 110f, 110f, 0.5f), 0f);
        assertEquals(0f, scroll.update(true, true, 140f, 110f, 2f), 0f);
        assertEquals(20f, scroll.update(true, true, 140f, 100f, 2f), 0f);
    }

    @Test
    public void stopsAndRebaselinesWhenButtonOrHoverEnds() {
        StylusHoverScroll scroll = new StylusHoverScroll();
        scroll.update(true, true, 0f, 100f, 0.5f);
        assertEquals(0f, scroll.update(true, false, 0f, 140f, 0.5f), 0f);
        assertEquals(0f, scroll.update(true, true, 0f, 200f, 0.5f), 0f);
        assertEquals(0f, scroll.update(false, true, 0f, 220f, 0.5f), 0f);
        assertEquals(0f, scroll.update(true, true, 0f, 10f, 0.5f), 0f);
        assertEquals(-5f, scroll.update(true, true, 0f, 20f, 0.5f), 0f);
    }
}
