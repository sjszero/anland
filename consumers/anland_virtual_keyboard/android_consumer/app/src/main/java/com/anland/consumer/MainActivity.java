package com.anland.consumer;

import android.app.Activity;
import android.content.pm.ActivityInfo;
import android.os.Bundle;
import android.util.Log;
import android.view.InputDevice;
import android.view.KeyEvent;
import android.view.MotionEvent;
import android.view.PointerIcon;
import android.view.Surface;
import android.view.SurfaceHolder;
import android.view.SurfaceView;
import android.view.View;
import android.view.ViewConfiguration;
import android.view.ViewGroup;
import android.view.WindowInsets;
import android.view.WindowInsetsController;
import android.view.WindowManager;
import android.widget.FrameLayout;
import android.widget.Toast;

public class MainActivity extends Activity implements SurfaceHolder.Callback {

    private static final String TAG = "Anland";

    private SurfaceView surfaceView;
    private boolean surfaceReady = false;
    private VirtualKeyboardView keyboardView;
    private FrameLayout rootLayout;

    // 触摸板模式标志
    private boolean isTouchpadMode = false;

    // 鼠标绝对位置（像素）
    private float mouseX = 0;
    private float mouseY = 0;
    private int screenWidth = 1920;
    private int screenHeight = 1080;

    // ---------- 触摸板手势状态机 ----------
    private static final int STATE_IDLE = 0;
    private static final int STATE_ONE_FINGER = 1;
    private static final int STATE_TWO_FINGER = 2;
    private static final int STATE_DRAGGING = 3;
    private int currentState = STATE_IDLE;

    // 手指跟踪数据
    private float lastX1, lastY1;
    private float startX1, startY1;
    private float lastX2, lastY2;
    private long downTime1;
    private float touchSlop;

    // 候选标志
    private boolean isSingleTapCandidate = false;
    private boolean isTwoFingerTapCandidate = false;
    private boolean isThreeFingerTapCandidate = false;
    private boolean isDraggingActive = false;

    // 双击
    private long lastTapTime = 0;
    private float lastTapX, lastTapY;
    private boolean isDoubleTapPending = false;

    // 长按
    private static final long LONG_PRESS_TIMEOUT = 500;
    private boolean hasLongPressed = false;
    private boolean isLongPressPossible = false;

    // 多指标志
    private boolean isMultiFinger = false;

    // 加速度
    private static final float BASE_SCALE = 1.0f;
    private static final float MAX_SCALE = 6.0f;
    private static final float SCALE_STEP = 0.125f;

    // 鼠标按钮
    private static final int BTN_LEFT = 0x110;
    private static final int BTN_RIGHT = 0x111;
    private static final int BTN_MIDDLE = 0x112;

    static {
        System.loadLibrary("anland_consumer");
    }

    private native void nativeStart(Surface surface);
    private native void nativeStop();
    private native void nativeSendTouch(int action, float x, float y, int pointerId);
    private native void nativeSendTouchFrame();
    private native void nativeSendKey(int action, int keycode);
    private native void nativeSendMouseMotion(float x, float y);
    private native void nativeSendMouseButton(int button, boolean pressed);
    private native void nativeSendMouseScroll(int axis, float value);

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        setRequestedOrientation(ActivityInfo.SCREEN_ORIENTATION_SENSOR_LANDSCAPE);
        getWindow().addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);
        getWindow().setSoftInputMode(WindowManager.LayoutParams.SOFT_INPUT_STATE_ALWAYS_HIDDEN);
        getWindow().addFlags(WindowManager.LayoutParams.FLAG_LAYOUT_NO_LIMITS);

        touchSlop = ViewConfiguration.get(this).getScaledTouchSlop();
        updateScreenSize();

        rootLayout = new FrameLayout(this);
        rootLayout.setClipChildren(false);
        rootLayout.setClipToPadding(false);
        rootLayout.setFitsSystemWindows(false);

        surfaceView = new SurfaceView(this);
        surfaceView.getHolder().addCallback(this);
        rootLayout.addView(surfaceView, new FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.MATCH_PARENT));

        keyboardView = new VirtualKeyboardView(this);
        keyboardView.setVisibility(View.GONE);
        keyboardView.setOnKeyEventListener(new VirtualKeyboardView.OnKeyEventListener() {
            @Override
            public void onKeyDown(int scanCode) {
                nativeSendKey(0, scanCode);
            }
            @Override
            public void onKeyUp(int scanCode) {
                nativeSendKey(1, scanCode);
            }
        });

        rootLayout.addView(keyboardView, new FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.WRAP_CONTENT,
                ViewGroup.LayoutParams.WRAP_CONTENT));

        setContentView(rootLayout);

        View decorView = getWindow().getDecorView();
        if (decorView instanceof ViewGroup) {
            ((ViewGroup) decorView).setClipChildren(false);
            ((ViewGroup) decorView).setClipToPadding(false);
        }

        keyboardView.post(() -> {
            try {
                keyboardView.setInitialPosition();
            } catch (Exception e) {
                Log.e(TAG, "Initial position error", e);
            }
        });

        setupFullscreen();
        setupCursorHiding();
        enterLockTask();

        mouseX = screenWidth / 2f;
        mouseY = screenHeight / 2f;
    }

    private void updateScreenSize() {
        android.graphics.Point size = new android.graphics.Point();
        getWindowManager().getDefaultDisplay().getSize(size);
        screenWidth = size.x;
        screenHeight = size.y;
        Log.d(TAG, "Screen size: " + screenWidth + "x" + screenHeight);
    }

    @Override
    protected void onResume() {
        super.onResume();
        setRequestedOrientation(ActivityInfo.SCREEN_ORIENTATION_SENSOR_LANDSCAPE);
        setupFullscreen();
        updateScreenSize();

        View decorView = getWindow().getDecorView();
        if (decorView instanceof ViewGroup) {
            ((ViewGroup) decorView).setClipChildren(false);
            ((ViewGroup) decorView).setClipToPadding(false);
        }

        if (surfaceReady && surfaceView != null && surfaceView.getHolder().getSurface() != null
                && surfaceView.getHolder().getSurface().isValid()) {
            try {
                nativeStop();
                nativeStart(surfaceView.getHolder().getSurface());
            } catch (Exception e) {
                Log.e(TAG, "nativeStart failed in onResume", e);
            }
        }
    }

    @Override
    protected void onPause() {
        super.onPause();
        try {
            nativeStop();
        } catch (Exception e) {
            Log.e(TAG, "nativeStop failed in onPause", e);
        }
    }

    @Override
    public void surfaceCreated(SurfaceHolder holder) {}

    @Override
    public void surfaceChanged(SurfaceHolder holder, int format, int width, int height) {
        Log.i(TAG, "surfaceChanged: " + width + "x" + height);
        surfaceReady = true;
        updateScreenSize();

        Surface surface = holder.getSurface();
        if (surface != null && surface.isValid()) {
            try {
                nativeStop();
                nativeStart(surface);
            } catch (Exception e) {
                Log.e(TAG, "nativeStart failed in surfaceChanged", e);
            }
        } else {
            Log.w(TAG, "Surface is invalid, skipping nativeStart");
        }

        if (keyboardView != null) {
            keyboardView.post(() -> {
                try {
                    keyboardView.setInitialPosition();
                } catch (Exception e) {
                    Log.e(TAG, "setInitialPosition error in surfaceChanged", e);
                }
            });
        }
    }

    @Override
    public void surfaceDestroyed(SurfaceHolder holder) {
        surfaceReady = false;
        try {
            nativeStop();
        } catch (Exception e) {
            Log.e(TAG, "nativeStop failed in surfaceDestroyed", e);
        }
    }

    private void setupFullscreen() {
        WindowInsetsController ctrl = getWindow().getInsetsController();
        if (ctrl != null) {
            ctrl.hide(WindowInsets.Type.statusBars() | WindowInsets.Type.navigationBars());
            ctrl.setSystemBarsBehavior(WindowInsetsController.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE);
        }
        getWindow().getDecorView().setSystemUiVisibility(
                View.SYSTEM_UI_FLAG_LAYOUT_STABLE |
                View.SYSTEM_UI_FLAG_LAYOUT_HIDE_NAVIGATION |
                View.SYSTEM_UI_FLAG_LAYOUT_FULLSCREEN
        );
    }

    private void enterLockTask() {
        try { startLockTask(); } catch (Exception e) { Log.w(TAG, "lockTask failed", e); }
    }

    private void setupCursorHiding() {
        surfaceView.setPointerIcon(PointerIcon.getSystemIcon(this, PointerIcon.TYPE_NULL));
    }

    @Override
    public boolean onKeyDown(int keyCode, KeyEvent event) {
        if (keyCode == KeyEvent.KEYCODE_VOLUME_UP) {
            isTouchpadMode = !isTouchpadMode;
            Toast.makeText(this, isTouchpadMode ? "触摸板模式（相对移动）" : "普通触摸模式（绝对定位）", Toast.LENGTH_SHORT).show();
            resetTouchpadState();
            return true;
        }
        if (keyCode == KeyEvent.KEYCODE_VOLUME_DOWN) {
            if (keyboardView != null) {
                try {
                    boolean show = keyboardView.getVisibility() == View.GONE;
                    keyboardView.setVisibility(show ? View.VISIBLE : View.GONE);
                    if (show) {
                        keyboardView.post(() -> {
                            try {
                                keyboardView.setInitialPosition();
                                keyboardView.bringToFront();
                            } catch (Exception e) {
                                Log.e(TAG, "Error showing keyboard", e);
                            }
                        });
                    }
                } catch (Exception e) {
                    Log.e(TAG, "Failed to toggle keyboard visibility", e);
                }
            }
            return true;
        }
        if (event.getRepeatCount() == 0) {
            int scan = event.getScanCode();
            if (scan != 0) { nativeSendKey(0, scan); return true; }
        }
        return super.onKeyDown(keyCode, event);
    }

    @Override
    public boolean onKeyUp(int keyCode, KeyEvent event) {
        if (keyCode == KeyEvent.KEYCODE_VOLUME_UP) return true;
        if (keyCode == KeyEvent.KEYCODE_VOLUME_DOWN) return true;
        int scan = event.getScanCode();
        if (scan != 0) { nativeSendKey(1, scan); return true; }
        return super.onKeyUp(keyCode, event);
    }

    @Override
    public boolean onTouchEvent(MotionEvent event) {
        if (isTouchpadMode) {
            return handleTouchpadGesture(event);
        } else {
            return handleTouchEventWithMouseFollow(event);
        }
    }

    @Override
    public boolean onGenericMotionEvent(MotionEvent event) {
        if (isMouseEvent(event)) {
            int action = event.getActionMasked();
            if (action == MotionEvent.ACTION_HOVER_MOVE) {
                float x = event.getX();
                float y = event.getY();
                mouseX = clamp(x, 0, screenWidth);
                mouseY = clamp(y, 0, screenHeight);
                nativeSendMouseMotion(mouseX, mouseY);
                return true;
            }
            if (action == MotionEvent.ACTION_SCROLL) {
                float v = event.getAxisValue(MotionEvent.AXIS_VSCROLL);
                float h = event.getAxisValue(MotionEvent.AXIS_HSCROLL);
                if (v != 0) nativeSendMouseScroll(0, -v * 10);
                if (h != 0) nativeSendMouseScroll(1, h * 10);
                return true;
            }
        }
        return super.onGenericMotionEvent(event);
    }

    private boolean handleTouchEventWithMouseFollow(MotionEvent event) {
        int action = event.getActionMasked();
        if (action == MotionEvent.ACTION_DOWN || action == MotionEvent.ACTION_POINTER_DOWN ||
            action == MotionEvent.ACTION_MOVE) {
            if (event.getPointerCount() > 0) {
                float fx = event.getX(0);
                float fy = event.getY(0);
                mouseX = clamp(fx, 0, screenWidth);
                mouseY = clamp(fy, 0, screenHeight);
                nativeSendMouseMotion(mouseX, mouseY);
            }
        }
        return handleTouchEvent(event);
    }

    private boolean handleTouchEvent(MotionEvent event) {
        int action = event.getActionMasked();
        int idx = event.getActionIndex();
        int pid = event.getPointerId(idx);
        switch (action) {
            case MotionEvent.ACTION_DOWN:
            case MotionEvent.ACTION_POINTER_DOWN:
                nativeSendTouch(0, event.getX(idx), event.getY(idx), pid);
                nativeSendTouchFrame();
                return true;
            case MotionEvent.ACTION_UP:
            case MotionEvent.ACTION_POINTER_UP:
                nativeSendTouch(1, event.getX(idx), event.getY(idx), pid);
                nativeSendTouchFrame();
                return true;
            case MotionEvent.ACTION_MOVE:
                for (int i = 0; i < event.getPointerCount(); i++) {
                    nativeSendTouch(2, event.getX(i), event.getY(i), event.getPointerId(i));
                }
                nativeSendTouchFrame();
                return true;
            case MotionEvent.ACTION_CANCEL:
                for (int i = 0; i < event.getPointerCount(); i++) {
                    nativeSendTouch(1, event.getX(i), event.getY(i), event.getPointerId(i));
                }
                nativeSendTouchFrame();
                return true;
        }
        return false;
    }

    // ========================================================================
    // 触摸板手势核心引擎
    // ========================================================================
    private boolean handleTouchpadGesture(MotionEvent event) {
        int action = event.getActionMasked();
        int pointerCount = event.getPointerCount();

        switch (action) {
            case MotionEvent.ACTION_DOWN: {
                float x = event.getX();
                float y = event.getY();
                startX1 = lastX1 = x;
                startY1 = lastY1 = y;
                downTime1 = event.getEventTime();
                hasLongPressed = false;
                isLongPressPossible = true;
                isSingleTapCandidate = true;
                isTwoFingerTapCandidate = false;
                isThreeFingerTapCandidate = false;
                isDoubleTapPending = false;
                isMultiFinger = false;
                currentState = STATE_ONE_FINGER;
                break;
            }

            case MotionEvent.ACTION_POINTER_DOWN: {
                isMultiFinger = true;
                isSingleTapCandidate = false;
                isDoubleTapPending = false;
                isLongPressPossible = false;
                if (currentState == STATE_DRAGGING) {
                    nativeSendMouseButton(BTN_LEFT, false);
                    isDraggingActive = false;
                }

                if (pointerCount == 2) {
                    currentState = STATE_TWO_FINGER;
                    isTwoFingerTapCandidate = true;
                    isThreeFingerTapCandidate = false;
                    lastX1 = event.getX(0);
                    lastY1 = event.getY(0);
                    lastX2 = event.getX(1);
                    lastY2 = event.getY(1);
                } else if (pointerCount == 3) {
                    currentState = STATE_IDLE;
                    isTwoFingerTapCandidate = false;
                    isThreeFingerTapCandidate = true;
                    lastX1 = event.getX(0);
                    lastY1 = event.getY(0);
                }
                break;
            }

            case MotionEvent.ACTION_MOVE: {
                if (pointerCount == 1 && !isMultiFinger) {
                    float x = event.getX();
                    float y = event.getY();
                    float dx = x - lastX1;
                    float dy = y - lastY1;
                    float dist = (float) Math.hypot(x - startX1, y - startY1);
                    if (dist > touchSlop) {
                        isLongPressPossible = false;
                        isSingleTapCandidate = false;
                    }

                    if (isLongPressPossible && !hasLongPressed &&
                        (event.getEventTime() - downTime1) >= LONG_PRESS_TIMEOUT) {
                        hasLongPressed = true;
                        currentState = STATE_DRAGGING;
                        isDraggingActive = true;
                        nativeSendMouseButton(BTN_LEFT, true);
                        mouseX = clamp(mouseX, 0, screenWidth);
                        mouseY = clamp(mouseY, 0, screenHeight);
                        nativeSendMouseMotion(mouseX, mouseY);
                        break;
                    }

                    if (currentState != STATE_DRAGGING && (Math.abs(dx) > 1 || Math.abs(dy) > 1)) {
                        mouseX = clamp(mouseX + dx * getAcceleration(dx, dy), 0, screenWidth);
                        mouseY = clamp(mouseY + dy * getAcceleration(dx, dy), 0, screenHeight);
                        nativeSendMouseMotion(mouseX, mouseY);
                        lastX1 = x;
                        lastY1 = y;
                    } else if (currentState == STATE_DRAGGING) {
                        if (Math.abs(dx) > 1 || Math.abs(dy) > 1) {
                            mouseX = clamp(mouseX + dx * getAcceleration(dx, dy), 0, screenWidth);
                            mouseY = clamp(mouseY + dy * getAcceleration(dx, dy), 0, screenHeight);
                            nativeSendMouseMotion(mouseX, mouseY);
                            lastX1 = x;
                            lastY1 = y;
                        }
                    }
                } else if (pointerCount == 2) {
                    if (currentState == STATE_TWO_FINGER) {
                        float x1 = event.getX(0);
                        float y1 = event.getY(0);
                        float x2 = event.getX(1);
                        float y2 = event.getY(1);
                        float avgDx = ((x1 - lastX1) + (x2 - lastX2)) / 2;
                        float avgDy = ((y1 - lastY1) + (y2 - lastY2)) / 2;
                        if (Math.abs(avgDx) > 1 || Math.abs(avgDy) > 1) {
                            isTwoFingerTapCandidate = false;
                            if (Math.abs(avgDy) > Math.abs(avgDx) * 0.5) {
                                nativeSendMouseScroll(0, -avgDy);
                            }
                            if (Math.abs(avgDx) > Math.abs(avgDy) * 0.5) {
                                nativeSendMouseScroll(1, avgDx);
                            }
                            lastX1 = x1;
                            lastY1 = y1;
                            lastX2 = x2;
                            lastY2 = y2;
                        }
                    }
                } else if (pointerCount >= 3) {
                    if (isThreeFingerTapCandidate) {
                        float x1 = event.getX(0);
                        float y1 = event.getY(0);
                        float dist = (float) Math.hypot(x1 - lastX1, y1 - lastY1);
                        if (dist > touchSlop) {
                            isThreeFingerTapCandidate = false;
                        }
                    }
                }
                break;
            }

            case MotionEvent.ACTION_POINTER_UP: {
                int remaining = pointerCount - 1;
                if (remaining == 1) {
                    // 多指变单指：保留双指/三指候选标志（如果尚未移动），但取消单指候选
                    isMultiFinger = false;
                    // 不清除 isTwoFingerTapCandidate 和 isThreeFingerTapCandidate
                    // 以便 ACTION_UP 中能够检测到双指/三指点击
                    isSingleTapCandidate = false;
                    isDoubleTapPending = false;
                    isLongPressPossible = false;
                    // 更新单指位置为剩余手指
                    int idx = (event.getActionIndex() == 0) ? 1 : 0;
                    lastX1 = event.getX(idx);
                    lastY1 = event.getY(idx);
                    startX1 = lastX1;
                    startY1 = lastY1;
                    downTime1 = event.getEventTime();
                    hasLongPressed = false;
                    currentState = STATE_ONE_FINGER;
                } else if (remaining == 0) {
                    // 所有手指抬起（不会到这里，因为会触发 ACTION_UP）
                }
                break;
            }

            case MotionEvent.ACTION_UP: {
                long duration = event.getEventTime() - downTime1;
                boolean isQuickTap = duration < 300;

                if (isDraggingActive) {
                    nativeSendMouseButton(BTN_LEFT, false);
                    isDraggingActive = false;
                    resetTouchpadState();
                    return true;
                }

                // 优先检测多指点击（此时 isMultiFinger 应为 false，因为最后一指抬起前已变单指）
                // 但注意：如果是三指同时抬起，则是从3→2→1，最后 ACTION_UP，此时 isMultiFinger 为 false
                if (isThreeFingerTapCandidate && isQuickTap) {
                    nativeSendMouseButton(BTN_MIDDLE, true);
                    nativeSendMouseButton(BTN_MIDDLE, false);
                    Log.d(TAG, "三指单击 → 中键");
                    resetTouchpadState();
                    return true;
                }

                if (isTwoFingerTapCandidate && isQuickTap) {
                    nativeSendMouseButton(BTN_RIGHT, true);
                    nativeSendMouseButton(BTN_RIGHT, false);
                    Log.d(TAG, "双指单击 → 右键");
                    resetTouchpadState();
                    return true;
                }

                // 单指点击 / 双击
                if (currentState == STATE_ONE_FINGER && isSingleTapCandidate && isQuickTap) {
                    long gap = event.getEventTime() - lastTapTime;
                    float dist = (float) Math.hypot(lastX1 - lastTapX, lastY1 - lastTapY);
                    if (gap < 300 && dist < touchSlop && !isDoubleTapPending) {
                        isDoubleTapPending = true;
                        nativeSendMouseButton(BTN_LEFT, true);
                        nativeSendMouseButton(BTN_LEFT, false);
                        nativeSendMouseButton(BTN_LEFT, true);
                        nativeSendMouseButton(BTN_LEFT, false);
                        Log.d(TAG, "单指双击 → 左键双击");
                        isDoubleTapPending = false;
                        lastTapTime = 0;
                    } else {
                        nativeSendMouseButton(BTN_LEFT, true);
                        nativeSendMouseButton(BTN_LEFT, false);
                        Log.d(TAG, "单指单击 → 左键单击");
                        lastTapTime = event.getEventTime();
                        lastTapX = lastX1;
                        lastTapY = lastY1;
                        isDoubleTapPending = false;
                    }
                    resetTouchpadState();
                    return true;
                }

                resetTouchpadState();
                break;
            }

            case MotionEvent.ACTION_CANCEL: {
                if (isDraggingActive) {
                    nativeSendMouseButton(BTN_LEFT, false);
                    isDraggingActive = false;
                }
                resetTouchpadState();
                break;
            }
        }
        return true;
    }

    private float getAcceleration(float dx, float dy) {
        float distance = (float) Math.hypot(dx, dy);
        float scale = BASE_SCALE + distance * SCALE_STEP;
        return Math.min(scale, MAX_SCALE);
    }

    private void resetTouchpadState() {
        currentState = STATE_IDLE;
        isSingleTapCandidate = false;
        isTwoFingerTapCandidate = false;
        isThreeFingerTapCandidate = false;
        isDoubleTapPending = false;
        hasLongPressed = false;
        isDraggingActive = false;
        isLongPressPossible = false;
        isMultiFinger = false;
        lastX1 = lastY1 = 0;
        lastX2 = lastY2 = 0;
    }

    private float clamp(float value, float min, float max) {
        return Math.max(min, Math.min(max, value));
    }

    // ---------- 鼠标/触摸辅助检测 ----------
    private static final int CLASSIFICATION_TWO_FINGER_SWIPE = 3;
    private static final int CLASSIFICATION_MULTI_FINGER_SWIPE = 4;
    private static final int CLASSIFICATION_PINCH = 5;
    private int savedBS = 0;
    private static final int[][] BUTTON_MAP = {
            {MotionEvent.BUTTON_PRIMARY, 0x110},
            {MotionEvent.BUTTON_SECONDARY, 0x111},
            {MotionEvent.BUTTON_TERTIARY, 0x112},
            {MotionEvent.BUTTON_BACK, 0x113},
            {MotionEvent.BUTTON_FORWARD, 0x114},
    };

    private boolean isMouseEvent(MotionEvent event) {
        int source = event.getSource();
        if ((source & InputDevice.SOURCE_TOUCHSCREEN) == InputDevice.SOURCE_TOUCHSCREEN) return false;
        if ((source & InputDevice.SOURCE_MOUSE) != InputDevice.SOURCE_MOUSE) return false;
        int toolType = event.getToolType(event.getActionIndex());
        return toolType == MotionEvent.TOOL_TYPE_MOUSE || toolType == MotionEvent.TOOL_TYPE_FINGER;
    }

    private boolean handleMouseEvent(MotionEvent event) {
        nativeSendMouseMotion(event.getX(), event.getY());
        int cur = event.getButtonState();
        for (int[] btn : BUTTON_MAP) {
            boolean was = (savedBS & btn[0]) != 0;
            boolean now = (cur & btn[0]) != 0;
            if (was != now) nativeSendMouseButton(btn[1], now);
        }
        savedBS = cur;
        return true;
    }

    private boolean handleTouchpadScroll(MotionEvent event) {
        if (event.getActionMasked() == MotionEvent.ACTION_MOVE) {
            float sx = event.getAxisValue(MotionEvent.AXIS_GESTURE_SCROLL_X_DISTANCE);
            float sy = event.getAxisValue(MotionEvent.AXIS_GESTURE_SCROLL_Y_DISTANCE);
            if (sy != 0) nativeSendMouseScroll(0, sy);
            if (sx != 0) nativeSendMouseScroll(1, -sx);
        }
        return true;
    }
}