/*
 * Presentation only: keep GStreamer's GL drawing and the audio/RTP paths.
 * AppKit work runs asynchronously on main; no native handle crosses threads.
 */
#import <Cocoa/Cocoa.h>
#include <dispatch/dispatch.h>
#include <cmath>
#include <gst/gl/gstglcontext.h>
#include <gst/gl/gstglwindow.h>
#include <gst/video/video.h>
#include "macos_airplay_window.h"

#include <objc/runtime.h>

/* All state below belongs to the AppKit main thread. */
static char ui_record_key;
static NSHashTable *ui_native_windows = nil;

static NSString *ui_profile_key(NSString *profile)
{
    return [@"AirPlay.Window.V1." stringByAppendingString:profile];
}

static gboolean ui_valid_rect(NSRect rect)
{
    return std::isfinite(NSMinX(rect)) && std::isfinite(NSMinY(rect)) &&
           std::isfinite(NSWidth(rect)) && std::isfinite(NSHeight(rect)) &&
           NSWidth(rect) >= 1.0 && NSHeight(rect) >= 1.0;
}

@interface UxAirPlayWindowRecord : NSObject {
@public
    NSString *profile; /* One of the immutable string literals below. */
    BOOL applying;
    BOOL fullscreen_transition;
}
- (void)saveWindow:(NSWindow *)window;
- (void)windowChanged:(NSNotification *)notification;
@end

@implementation UxAirPlayWindowRecord
- (void)saveWindow:(NSWindow *)window
{
    if (!profile || applying || fullscreen_transition || [window inLiveResize] ||
        ([window styleMask] & NSWindowStyleMaskFullScreen))
        return;
    NSRect content = [window contentRectForFrameRect:[window frame]];
    if (!ui_valid_rect(content))
        return;

    NSMutableDictionary *saved = [NSMutableDictionary dictionaryWithObject:
                                  NSStringFromRect(content) forKey:@"content"];
    NSNumber *screen_id = [[[window screen] deviceDescription] objectForKey:@"NSScreenNumber"];
    if (screen_id)
        [saved setObject:screen_id forKey:@"screen"];
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSString *key = ui_profile_key(profile);
    if (![[defaults objectForKey:key] isEqual:saved])
        [defaults setObject:saved forKey:key];
}

- (void)windowChanged:(NSNotification *)notification
{
    if (![NSThread isMainThread])
        return;
    id object = [notification object];
    if (![object isKindOfClass:[NSWindow class]] ||
        objc_getAssociatedObject(object, &ui_record_key) != self)
        return;
    NSWindow *window = (NSWindow *)object;
    NSString *name = [notification name];
    if ([name isEqualToString:NSWindowWillEnterFullScreenNotification]) {
        [self saveWindow:window];
        fullscreen_transition = YES;
        return;
    }
    if ([name isEqualToString:NSWindowWillExitFullScreenNotification]) {
        fullscreen_transition = YES;
        return;
    }
    if ([name isEqualToString:NSWindowDidEnterFullScreenNotification]) {
        fullscreen_transition = NO;
        return;
    }
    if ([name isEqualToString:NSWindowDidExitFullScreenNotification])
        fullscreen_transition = NO;

    [self saveWindow:window];
    if ([name isEqualToString:NSWindowWillCloseNotification]) {
        [ui_native_windows removeObject:window];
        [[NSNotificationCenter defaultCenter] removeObserver:self];
    }
}

- (void)dealloc
{
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [super dealloc];
}
@end

static UxAirPlayWindowRecord *ui_record(NSWindow *window)
{
    UxAirPlayWindowRecord *record = (UxAirPlayWindowRecord *)
        objc_getAssociatedObject(window, &ui_record_key);
    if (record)
        return record;
    record = [[[UxAirPlayWindowRecord alloc] init] autorelease];
    objc_setAssociatedObject(window, &ui_record_key, record, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    /*
     * No registration captures the window. The association check above limits
     * all notifications to this GL window and keeps other app windows untouched.
     */
    NSArray *names = @[NSWindowDidMoveNotification, NSWindowDidResizeNotification,
                       NSWindowDidEndLiveResizeNotification, NSWindowWillCloseNotification,
                       NSWindowWillEnterFullScreenNotification, NSWindowDidEnterFullScreenNotification,
                       NSWindowWillExitFullScreenNotification, NSWindowDidExitFullScreenNotification];
    for (NSString *name in names)
        [[NSNotificationCenter defaultCenter] addObserver:record
            selector:@selector(windowChanged:) name:name object:nil];
    if (!ui_native_windows)
        ui_native_windows = [[NSHashTable weakObjectsHashTable] retain];
    [ui_native_windows addObject:window];
    return record;
}

gboolean ux_macos_airplay_window_show(void)
{
    if (![NSThread isMainThread])
        return FALSE;
    for (NSWindow *window in [ui_native_windows allObjects]) {
        if (!objc_getAssociatedObject(window, &ui_record_key))
            continue;
        if ([window isMiniaturized])
            [window deminiaturize:nil];
        [window makeKeyAndOrderFront:nil];
        return TRUE;
    }
    return FALSE;
}

void ux_macos_airplay_window_save(void)
{
    if (![NSThread isMainThread])
        return;
    for (NSWindow *window in [ui_native_windows allObjects]) {
        UxAirPlayWindowRecord *record = (UxAirPlayWindowRecord *)
            objc_getAssociatedObject(window, &ui_record_key);
        [record saveWindow:window];
    }
    /* Explicit app Quit can return through the GStreamer wrapper, without -terminate:. */
    BOOL flushed = [[NSUserDefaults standardUserDefaults] synchronize];
    g_printerr("AIRPLAY_UI preferences_flush=%d\n", (int)flushed);
}

struct UiState {
    gint refs;
    GMutex mutex;
    GWeakRef window; /* Avoid a sink -> state -> window -> sink reference cycle. */
    gboolean active;
    gboolean queued;
    gint width, height, par_n, par_d;
    guint64 revision, applied_revision;
    gint64 retry_after;
};

static UiState *ui_ref(UiState *state)
{
    g_atomic_int_inc(&state->refs);
    return state;
}

static void ui_unref(UiState *state)
{
    if (g_atomic_int_dec_and_test(&state->refs)) {
        g_weak_ref_clear(&state->window);
        g_mutex_clear(&state->mutex);
        g_free(state);
    }
}

/* Called only on main, where the Cocoa backend creates/closes its NSWindow. */
static gboolean ui_apply_window(GstGLWindow *window, gint width, gint height,
                                gint par_n, gint par_d)
{
    if (g_strcmp0(G_OBJECT_TYPE_NAME(window), "GstGLWindowCocoa") != 0)
        return FALSE;

    guintptr handle = gst_gl_window_get_window_handle(window);
    if (!handle)
        return FALSE;
    NSWindow *native = (NSWindow *)handle;
    if (![native isKindOfClass:[NSWindow class]])
        return FALSE;

    /* Keep it alive across synchronous AppKit notifications during resize. */
    [[native retain] autorelease];
    if (![native isVisible])
        return FALSE;
    UxAirPlayWindowRecord *record = ui_record(native);

    if (![[native title] isEqualToString:@"AirPlay"]) {
        [native setTitle:@"AirPlay"];
        g_printerr("AIRPLAY_UI title=AirPlay\n");
    }
    if (record->fullscreen_transition ||
        ([native styleMask] & NSWindowStyleMaskFullScreen) || [native inLiveResize])
        return FALSE; /* Leave this revision pending until a later frame. */

    const double aspect = ((double)width * par_n) / ((double)height * par_d);
    if (!std::isfinite(aspect) || aspect <= 0.0)
        return FALSE;
    NSString *new_profile = aspect >= 1.0 ? @"landscape" : @"portrait";
    if ([new_profile isEqualToString:record->profile])
        return TRUE; /* Resolution changes within an orientation keep manual geometry. */

    NSRect old_frame = [native frame];
    NSRect old_content = [native contentRectForFrameRect:old_frame];
    NSRect desired = NSZeroRect;
    BOOL restored = NO;
    NSScreen *screen = [native screen];
    id saved = [[NSUserDefaults standardUserDefaults] objectForKey:ui_profile_key(new_profile)];
    if ([saved isKindOfClass:[NSDictionary class]]) {
        id content = [saved objectForKey:@"content"];
        if ([content isKindOfClass:[NSString class]]) {
            desired = NSRectFromString(content);
            restored = ui_valid_rect(desired);
        }
        id screen_id = [saved objectForKey:@"screen"];
        if (restored && [screen_id isKindOfClass:[NSNumber class]]) {
            for (NSScreen *candidate in [NSScreen screens]) {
                if ([[[candidate deviceDescription] objectForKey:@"NSScreenNumber"] isEqual:screen_id]) {
                    screen = candidate;
                    break;
                }
            }
        }
    }
    if (!screen)
        screen = [NSScreen mainScreen];
    if (!screen)
        return FALSE;

    NSRect available = NSInsetRect([screen visibleFrame], 8.0, 8.0);
    const CGFloat decoration_w = NSWidth(old_frame) - NSWidth(old_content);
    const CGFloat decoration_h = NSHeight(old_frame) - NSHeight(old_content);
    const CGFloat max_w = NSWidth(available) - decoration_w;
    const CGFloat max_h = NSHeight(available) - decoration_h;
    if (max_w < 1.0 || max_h < 1.0)
        return FALSE;

    if (!restored) {
        CGFloat long_side = MAX(NSWidth(old_content), NSHeight(old_content));
        if (long_side < 1.0)
            long_side = 640.0;
        desired.size.width = aspect >= 1.0 ? long_side : long_side * aspect;
        desired.size.height = aspect >= 1.0 ? long_side / aspect : long_side;
    }
    const CGFloat scale = MIN(1.0, MIN(max_w / NSWidth(desired), max_h / NSHeight(desired)));
    desired.size.width = MAX(1.0, std::floor(NSWidth(desired) * scale));
    desired.size.height = MAX(1.0, std::floor(NSHeight(desired) * scale));
    NSRect frame = [native frameRectForContentRect:desired];
    if (!restored) {
        frame.origin.x = NSMidX(old_frame) - NSWidth(frame) / 2.0;
        frame.origin.y = NSMidY(old_frame) - NSHeight(frame) / 2.0;
    }
    frame.origin.x = MAX(NSMinX(available),
                         MIN(frame.origin.x, NSMaxX(available) - NSWidth(frame)));
    frame.origin.y = MAX(NSMinY(available),
                         MIN(frame.origin.y, NSMaxY(available) - NSHeight(frame)));

    record->applying = YES;
    record->profile = new_profile;
    if (!NSEqualRects(frame, old_frame))
        [native setFrame:frame display:YES animate:NO];
    record->applying = NO;
    [record saveWindow:native];

    NSRect actual_frame = [native frame];
    NSRect actual_content = [native contentRectForFrameRect:actual_frame];
    g_printerr("AIRPLAY_UI profile=%s restored=%d video=%dx%d par=%d/%d aspect=%.6f "
               "content=%.0fx%.0f frame=%.0f,%.0f,%.0f,%.0f\n",
               [new_profile UTF8String], (int)restored, width, height, par_n, par_d, aspect,
               (double)NSWidth(actual_content), (double)NSHeight(actual_content),
               (double)NSMinX(actual_frame), (double)NSMinY(actual_frame),
               (double)NSWidth(actual_frame), (double)NSHeight(actual_frame));
    return TRUE;
}

static void ui_apply_on_main(void *data)
{
    UiState *state = (UiState *)data;
    GstGLWindow *window = NULL;
    gint width = 0, height = 0, par_n = 1, par_d = 1;
    guint64 revision = 0;

    g_mutex_lock(&state->mutex);
    if (state->active) {
        window = (GstGLWindow *)g_weak_ref_get(&state->window);
        width = state->width;
        height = state->height;
        par_n = state->par_n;
        par_d = state->par_d;
        revision = state->revision;
    }
    g_mutex_unlock(&state->mutex);

    gboolean applied = FALSE;
    if (window) {
        @autoreleasepool {
            applied = ui_apply_window(window, width, height, par_n, par_d);
        }
        gst_object_unref(window);
    }

    g_mutex_lock(&state->mutex);
    if (applied)
        state->applied_revision = revision;
    state->retry_after = applied ? 0 : g_get_monotonic_time() + 250000;
    state->queued = FALSE;
    g_mutex_unlock(&state->mutex);
    ui_unref(state);
}

static gboolean ui_client_draw(GstElement *, GstGLContext *context,
                               GstSample *sample, gpointer data)
{
    UiState *state = (UiState *)data;
    GstVideoInfo info;
    GstCaps *caps = gst_sample_get_caps(sample);
    gst_video_info_init(&info);
    if (!caps || !gst_video_info_from_caps(&info, caps) ||
        GST_VIDEO_INFO_WIDTH(&info) <= 0 || GST_VIDEO_INFO_HEIGHT(&info) <= 0 ||
        GST_VIDEO_INFO_PAR_N(&info) <= 0 || GST_VIDEO_INFO_PAR_D(&info) <= 0)
        return FALSE;

    GstGLWindow *window = gst_gl_context_get_window(context); /* transfer full */
    if (!window)
        return FALSE;

    gboolean queue = FALSE;
    g_mutex_lock(&state->mutex);
    GstGLWindow *previous = (GstGLWindow *)g_weak_ref_get(&state->window);
    if (state->active &&
        (previous != window || state->width != GST_VIDEO_INFO_WIDTH(&info) ||
         state->height != GST_VIDEO_INFO_HEIGHT(&info) ||
         state->par_n != GST_VIDEO_INFO_PAR_N(&info) ||
         state->par_d != GST_VIDEO_INFO_PAR_D(&info))) {
        g_weak_ref_set(&state->window, window);
        state->width = GST_VIDEO_INFO_WIDTH(&info);
        state->height = GST_VIDEO_INFO_HEIGHT(&info);
        state->par_n = GST_VIDEO_INFO_PAR_N(&info);
        state->par_d = GST_VIDEO_INFO_PAR_D(&info);
        ++state->revision;
        state->retry_after = 0;
    }
    if (state->active && state->revision != state->applied_revision &&
        !state->queued && g_get_monotonic_time() >= state->retry_after) {
        state->queued = TRUE;
        ui_ref(state);
        queue = TRUE;
    }
    g_mutex_unlock(&state->mutex);
    if (previous)
        gst_object_unref(previous);
    gst_object_unref(window);

    /* client-draw holds GStreamer's draw lock: never wait for AppKit here. */
    if (queue)
        dispatch_async_f(dispatch_get_main_queue(), state, ui_apply_on_main);
    return FALSE; /* Always keep GStreamer's default GL rendering. */
}

static void ui_closure_destroy(gpointer data, GClosure *)
{
    UiState *state = (UiState *)data;
    g_mutex_lock(&state->mutex);
    state->active = FALSE;
    g_mutex_unlock(&state->mutex);
    ui_unref(state); /* Any pending main-queue job owns its own reference. */
}

void ux_macos_airplay_window_attach(GstElement *sink)
{
    GstElement *inner = NULL;
    if (!sink || !g_object_class_find_property(G_OBJECT_GET_CLASS(sink), "sink"))
        return;
    /* The bin is still in NULL. Reading this property does not touch the GL lock. */
    g_object_get(sink, "sink", &inner, NULL);
    if (!inner || !g_signal_lookup("client-draw", G_OBJECT_TYPE(inner))) {
        if (inner)
            gst_object_unref(inner);
        g_printerr("AIRPLAY_UI unavailable: no GL client-draw signal\n");
        return;
    }

    UiState *state = g_new0(UiState, 1);
    state->refs = 1;
    state->active = TRUE;
    g_mutex_init(&state->mutex);
    g_weak_ref_init(&state->window, NULL);
    /*
     * Attach after the internal forwarding handler, not to the public bin.
     * A bin client-draw handler changes GStreamer's shader initialization test.
     */
    g_signal_connect_data(inner, "client-draw", G_CALLBACK(ui_client_draw),
                          state, ui_closure_destroy, G_CONNECT_AFTER);
    g_printerr("AIRPLAY_UI attached sink=%s\n", GST_ELEMENT_NAME(sink));
    gst_object_unref(inner);
}
