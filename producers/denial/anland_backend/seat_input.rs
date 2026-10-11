//! Smithay event objects only. No socket reads, wire decoding or new protocol.
use super::client::Input;
use smithay::backend::input::*;
use std::collections::BTreeSet;
use std::path::PathBuf;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct AnlandDevice;
impl Device for AnlandDevice {
    fn id(&self) -> String {
        "anland-consumer".into()
    }
    fn name(&self) -> String {
        "Anland consumer input".into()
    }
    fn has_capability(&self, c: DeviceCapability) -> bool {
        matches!(
            c,
            DeviceCapability::Keyboard | DeviceCapability::Pointer | DeviceCapability::Touch
        )
    }
    fn usb_id(&self) -> Option<(u32, u32)> {
        None
    }
    fn syspath(&self) -> Option<PathBuf> {
        None
    }
}

#[derive(Debug, Clone, Copy)]
pub struct NativeEvent {
    time: u64,
    extent: (u32, u32),
    raw: Input,
    key_count: u32,
}
impl Event<AnlandInputBackend> for NativeEvent {
    fn time(&self) -> u64 {
        self.time
    }
    fn device(&self) -> AnlandDevice {
        AnlandDevice
    }
}
impl AbsolutePositionEvent<AnlandInputBackend> for NativeEvent {
    fn x(&self) -> f64 {
        self.raw.x.into()
    }
    fn y(&self) -> f64 {
        self.raw.y.into()
    }
    fn x_transformed(&self, width: i32) -> f64 {
        self.x() * f64::from(width) / f64::from(self.extent.0)
    }
    fn y_transformed(&self, height: i32) -> f64 {
        self.y() * f64::from(height) / f64::from(self.extent.1)
    }
}
impl KeyboardKeyEvent<AnlandInputBackend> for NativeEvent {
    // Public producer supplies evdev codes; Smithay's seat uses XKB (+8).
    fn key_code(&self) -> Keycode {
        Keycode::new(self.raw.code as u32 + 8)
    }
    fn state(&self) -> KeyState {
        if self.raw.action == 0 {
            KeyState::Pressed
        } else {
            KeyState::Released
        }
    }
    fn count(&self) -> u32 {
        self.key_count
    }
}
impl PointerMotionEvent<AnlandInputBackend> for NativeEvent {
    // Consumer deltas are physical pixels. The shared Flutter/Wayland route
    // divides by atlas_scale once; never apply a default scale/acceleration here.
    fn delta_x(&self) -> f64 {
        self.raw.dx.into()
    }
    fn delta_y(&self) -> f64 {
        self.raw.dy.into()
    }
    fn delta_x_unaccel(&self) -> f64 {
        self.delta_x()
    }
    fn delta_y_unaccel(&self) -> f64 {
        self.delta_y()
    }
}
impl PointerMotionAbsoluteEvent<AnlandInputBackend> for NativeEvent {}
impl PointerButtonEvent<AnlandInputBackend> for NativeEvent {
    fn button_code(&self) -> u32 {
        self.raw.code as u32
    }
    // Pointer pressed is boolean, NOT the touch/key DOWN=0 action enum.
    fn state(&self) -> ButtonState {
        if self.raw.action == 1 {
            ButtonState::Pressed
        } else {
            ButtonState::Released
        }
    }
}
impl PointerAxisEvent<AnlandInputBackend> for NativeEvent {
    fn amount(&self, axis: Axis) -> Option<f64> {
        self.matches_axis(axis).then_some(f64::from(self.raw.value))
    }
    fn amount_v120(&self, axis: Axis) -> Option<f64> {
        // Zero discrete means no wheel step metadata. Returning Some(0) would
        // discard smooth high-resolution scroll in Denial's existing route.
        (self.raw.discrete != 0 && self.matches_axis(axis))
            .then_some(f64::from(self.raw.discrete) * 120.)
    }
    fn source(&self) -> AxisSource {
        AxisSource::Wheel
    }
    fn relative_direction(&self, _: Axis) -> AxisRelativeDirection {
        AxisRelativeDirection::Identical
    }
}
impl NativeEvent {
    fn matches_axis(&self, axis: Axis) -> bool {
        matches!(
            (self.raw.code, axis),
            (0, Axis::Vertical) | (1, Axis::Horizontal)
        )
    }
}
impl TouchEvent<AnlandInputBackend> for NativeEvent {
    fn slot(&self) -> TouchSlot {
        TouchSlot::from(Some(self.raw.pointer_id as u32))
    }
}
impl TouchDownEvent<AnlandInputBackend> for NativeEvent {}
impl TouchMotionEvent<AnlandInputBackend> for NativeEvent {}
impl TouchUpEvent<AnlandInputBackend> for NativeEvent {}
impl TouchFrameEvent<AnlandInputBackend> for NativeEvent {}

#[derive(Debug, Default)]
pub struct AnlandInputBackend {
    keys: BTreeSet<i32>,
    buttons: BTreeSet<i32>,
    contacts: BTreeSet<i32>,
}
impl InputBackend for AnlandInputBackend {
    type Device = AnlandDevice;
    type KeyboardKeyEvent = NativeEvent;
    type PointerAxisEvent = NativeEvent;
    type PointerButtonEvent = NativeEvent;
    type PointerMotionEvent = NativeEvent;
    type PointerMotionAbsoluteEvent = NativeEvent;
    type GestureSwipeBeginEvent = UnusedEvent;
    type GestureSwipeUpdateEvent = UnusedEvent;
    type GestureSwipeEndEvent = UnusedEvent;
    type GesturePinchBeginEvent = UnusedEvent;
    type GesturePinchUpdateEvent = UnusedEvent;
    type GesturePinchEndEvent = UnusedEvent;
    type GestureHoldBeginEvent = UnusedEvent;
    type GestureHoldEndEvent = UnusedEvent;
    type TouchDownEvent = NativeEvent;
    type TouchUpEvent = NativeEvent;
    type TouchMotionEvent = NativeEvent;
    type TouchCancelEvent = UnusedEvent;
    type TouchFrameEvent = NativeEvent;
    type TabletToolAxisEvent = UnusedEvent;
    type TabletToolProximityEvent = UnusedEvent;
    type TabletToolTipEvent = UnusedEvent;
    type TabletToolButtonEvent = UnusedEvent;
    type SwitchToggleEvent = UnusedEvent;
    type SpecialEvent = ();
}
impl AnlandInputBackend {
    /// The native seat performs actual release/cancel before this local reset.
    pub fn reset(&mut self) {
        self.keys.clear();
        self.buttons.clear();
        self.contacts.clear();
    }
    /// Translation rejects invalid/orphan transitions rather than inventing an
    /// UP for an unknown key or turning a negative contact id into slot zero.
    pub fn translate(
        &mut self,
        raw: Input,
        extent: (u32, u32),
        time: u64,
    ) -> Option<InputEvent<Self>> {
        if extent.0 == 0 || extent.1 == 0 {
            return None;
        }
        match raw.kind {
            2 => {
                if !(1..=0x2ff).contains(&raw.code) || !matches!(raw.action, 0 | 1) {
                    return None;
                }
                let changed = if raw.action == 0 {
                    self.keys.insert(raw.code)
                } else {
                    self.keys.remove(&raw.code)
                };
                if !changed {
                    return None;
                } // Flutter/seat own key repeat.
            }
            3 => {
                if !raw.dx.is_finite() || !raw.dy.is_finite() {
                    return None;
                }
            }
            4 => {
                if !(0x110..=0x11f).contains(&raw.code) || !matches!(raw.action, 0 | 1) {
                    return None;
                }
                let changed = if raw.action == 1 {
                    self.buttons.insert(raw.code)
                } else {
                    self.buttons.remove(&raw.code)
                };
                if !changed {
                    return None;
                }
            }
            5 => {
                if !matches!(raw.code, 0 | 1) || !raw.value.is_finite() {
                    return None;
                }
            }
            1 => {
                if !(0..=65535).contains(&raw.pointer_id) {
                    return None;
                }
                if matches!(raw.action, 0 | 2) && (!raw.x.is_finite() || !raw.y.is_finite()) {
                    return None;
                }
                let changed = match raw.action {
                    0 => self.contacts.len() < 32 && self.contacts.insert(raw.pointer_id),
                    1 => self.contacts.remove(&raw.pointer_id),
                    2 => self.contacts.contains(&raw.pointer_id),
                    _ => false,
                };
                if !changed {
                    return None;
                }
            }
            6 => {}
            _ => return None,
        }
        let event = NativeEvent {
            time,
            extent,
            raw,
            key_count: self.keys.len() as u32,
        };
        Some(match raw.kind {
            2 => InputEvent::Keyboard { event },
            // Relative deltas preserve the original pointer constraints/locks.
            3 => InputEvent::PointerMotion { event },
            4 => InputEvent::PointerButton { event },
            5 => InputEvent::PointerAxis { event },
            1 => match raw.action {
                0 => InputEvent::TouchDown { event },
                1 => InputEvent::TouchUp { event },
                _ => InputEvent::TouchMotion { event },
            },
            _ => InputEvent::TouchFrame { event },
        })
    }
}
